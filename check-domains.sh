#!/usr/bin/env bash
#
# check-domains.sh
#
# Reads the active domain file written by fetch-domains.sh and processes
# BATCH_SIZE entries per invocation. Cycles through every telco in TELCO_LIST.
#
# State machine (per run):
#   1. POINTER == 0 and current telco not yet announced
#         -> echo "RUNNING DOMAIN CHECK WITH TELCO X"
#         -> record TELCO_STARTED_AT
#   2. Process BATCH_SIZE lines from POINTER, ping + HTTP probe each host.
#      For each blocked host:
#         -> add to in-memory batch for /domain-block-report
#         -> append remark to REMARKS_FILE
#   3. Flush block report at end (or every REPORT_BATCH_SIZE).
#   4. Advance POINTER. If POINTER >= TOTAL_LINES:
#         -> POST per-telco stats
#         -> if more telcos remain:
#              echo "CHANGING TO NEXT TELCO Y. PLEASE WAIT 2 MINS."
#              SWITCH_UNTIL = now + SWITCH_COOLDOWN_SECONDS
#              advance TELCO_INDEX, reset POINTER=0
#           else:
#              POST summary
#              echo "DONE CHECK AND SUMMARY STATISTIC SENT"
#              archive file, mark DONE=1
#   5. If SWITCH_UNTIL > now on entry: skip until cooldown elapses.
#
# Recommended cron entry (every 5 minutes):
#   */5 * * * *  /opt/domain-check/check-domains.sh >> /var/log/domain-check/check.log 2>&1

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# ----- MCMC block detection --------------------------------------------------
# Edit these directly (no config.sh change needed) to tune live without
# touching the shared config file.
#
# Patterns (case-insensitive, regex) detected as MCMC / regulator block pages.
# If the final URL OR the response body matches any of these, the domain is
# marked blocked with reason=mcmc_redirect.
MCMC_PATTERNS=(
    "skmm\\.gov\\.my"
    "mcmc"
)

# Known MCMC / regulator sinkhole IPs. If ping resolves the host to one of
# these, the domain is marked blocked with reason=mcmc_block_ip, regardless
# of packet loss.
MCMC_BLOCK_IPS=(
    "175.139.142.25"
)

load_config

acquire_lock

if [[ ! -f "${DOMAINS_FILE}" ]]; then
    sleep 2
    clear
    sleep 2
    log ""
    log "No active domain file (${DOMAINS_FILE}). Run fetch-domains.sh first. Skipping."
    exit 0
fi

DONE="$(state_get DONE)"
if [[ "${DONE}" == "1" ]]; then
    sleep 2
    clear
    sleep 2
    log ""
    log "Active file is already marked DONE. Awaiting fetch-domains.sh to start a new run."
    exit 0
fi

# Cooldown gate (2-min telco-switch wait).
SWITCH_UNTIL="$(state_get SWITCH_UNTIL)"
SWITCH_UNTIL="${SWITCH_UNTIL:-0}"
NOW_EPOCH="$(date +%s)"
if (( NOW_EPOCH < SWITCH_UNTIL )); then
    remaining=$(( SWITCH_UNTIL - NOW_EPOCH ))
    sleep 2
    clear
    sleep 2
    log ""
    log "Telco-switch cooldown active. ${remaining}s remaining. Skipping."
    exit 0
fi

# Resolve current telco.
TELCO_LIST_STR="$(state_get TELCO_LIST)"
IFS=',' read -r -a CURRENT_TELCOS <<< "${TELCO_LIST_STR}"
TELCO_INDEX="$(state_get TELCO_INDEX)"
TELCO_INDEX="${TELCO_INDEX:-0}"
TOTAL_TELCOS="${#CURRENT_TELCOS[@]}"
CURRENT_TELCO="${CURRENT_TELCOS[${TELCO_INDEX}]:-}"
[[ -z "${CURRENT_TELCO}" ]] && die "Could not resolve current telco (index=${TELCO_INDEX})."

TOTAL_LINES="$(state_get TOTAL_LINES)"
TOTAL_LINES="${TOTAL_LINES:-0}"
POINTER="$(state_get POINTER)"
POINTER="${POINTER:-0}"
RUN_ID="$(state_get RUN_ID)"
TELCO_BLOCK_COUNT="$(state_get TELCO_BLOCK_COUNT)"
TELCO_BLOCK_COUNT="${TELCO_BLOCK_COUNT:-0}"
ANNOUNCED_TELCO="$(state_get ANNOUNCED_TELCO)"

# First batch for a telco -> announce.
if (( POINTER == 0 )); then
    if [[ "${ANNOUNCED_TELCO}" != "${CURRENT_TELCO}" ]]; then
        log "RUNNING DOMAIN CHECK WITH TELCO ${CURRENT_TELCO}"
        state_set ANNOUNCED_TELCO  "${CURRENT_TELCO}"
        state_set TELCO_STARTED_AT "$(date '+%Y-%m-%d %H:%M:%S')"
        state_set TELCO_BLOCK_COUNT "0"
        TELCO_BLOCK_COUNT=0
    fi
fi

TELCO_STARTED_AT="$(state_get TELCO_STARTED_AT)"
TELCO_STARTED_EPOCH="$(date -d "${TELCO_STARTED_AT}" +%s 2>/dev/null || echo "${NOW_EPOCH}")"

# Slice the next BATCH_SIZE lines.
START_LINE=$(( POINTER + 1 ))
END_LINE=$(( POINTER + BATCH_SIZE ))
if (( END_LINE > TOTAL_LINES )); then
    END_LINE="${TOTAL_LINES}"
fi

if (( START_LINE > TOTAL_LINES )); then
    log "Pointer beyond EOF. Treating telco ${CURRENT_TELCO} as complete."
    BATCH_LINES=""
else
    BATCH_LINES="$(sed -n "${START_LINE},${END_LINE}p" "${DOMAINS_FILE}")"
fi

log "Telco=${CURRENT_TELCO} batch lines ${START_LINE}..${END_LINE} of ${TOTAL_LINES}"

declare -a BLOCK_BATCH=()
batch_count=0
new_blocks=0

flush_blocks() {
    local count=${#BLOCK_BATCH[@]}
    (( count == 0 )) && return
    local payload='{"checks":['
    local first=1 item
    for item in "${BLOCK_BATCH[@]}"; do
        if (( first == 1 )); then
            payload+="${item}"
            first=0
        else
            payload+=",${item}"
        fi
    done
    payload+=']}'
    if api_post_json "/cron/domain-block-report" "${payload}" >/dev/null; then
        log "Reported ${count} blocked entries to API."
    else
        log "WARN: failed to POST block report (${count} entries). Will keep remark log."
    fi
    BLOCK_BATCH=()
}

if [[ -n "${BATCH_LINES}" ]]; then
    while IFS='|' read -r merchant_id host; do
        [[ -z "${host}" ]] && continue
        check_one_domain "${host}"
        batch_count=$(( batch_count + 1 ))

        log "CHECK [$(( POINTER + batch_count ))/${TOTAL_LINES}] telco=${CURRENT_TELCO} mid=${merchant_id} host=${host} result=${CHECK_RESULT} reason=${CHECK_REASON} evidence=${CHECK_EVIDENCE}"

        if [[ "${CHECK_RESULT}" == "blocked" ]]; then
            new_blocks=$(( new_blocks + 1 ))

            ts="$(date '+%Y-%m-%d %H:%M:%S')"
            remark="[${ts}] BLOCKED telco=${CURRENT_TELCO} mid=${merchant_id} host=${host} reason=${CHECK_REASON} ${CHECK_EVIDENCE}"
            echo "${remark}" >> "${REMARKS_FILE}"

            json="{"
            json+="\"merchant_id\":${merchant_id},"
            json+="\"domain\":\"$(json_escape "${host}")\","
            json+="\"telco\":\"$(json_escape "${CURRENT_TELCO}")\","
            json+="\"status\":\"blocked\","
            json+="\"reason\":\"$(json_escape "${CHECK_REASON}")\","
            json+="\"evidence\":\"$(json_escape "${CHECK_EVIDENCE}")\","
            json+="\"packet_loss_pct\":${CHECK_LOSS_PCT},"
            json+="\"http_code\":${CHECK_HTTP_CODE},"
            json+="\"run_id\":\"$(json_escape "${RUN_ID}")\","
            json+="\"detected_at\":\"${ts}\""
            json+="}"
            BLOCK_BATCH+=("${json}")

            if (( ${#BLOCK_BATCH[@]} >= REPORT_BATCH_SIZE )); then
                flush_blocks
            fi
        fi
    done <<< "${BATCH_LINES}"
fi

flush_blocks

# Persist progress.
NEW_POINTER="${END_LINE}"
TELCO_BLOCK_COUNT=$(( TELCO_BLOCK_COUNT + new_blocks ))
state_set POINTER           "${NEW_POINTER}"
state_set TELCO_BLOCK_COUNT "${TELCO_BLOCK_COUNT}"

log "PROCESSED BATCH ${batch_count} domains this run (telco=${CURRENT_TELCO}, blocked_in_batch=${new_blocks}, telco_total_blocks=${TELCO_BLOCK_COUNT}, pointer=${NEW_POINTER}/${TOTAL_LINES})"

# Telco completed?
if (( NEW_POINTER >= TOTAL_LINES )); then
    TELCO_ENDED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
    TELCO_ENDED_EPOCH="$(date +%s)"
    duration=$(( TELCO_ENDED_EPOCH - TELCO_STARTED_EPOCH ))

    # POST per-telco stats.
    stats_payload="{"
    stats_payload+="\"run_id\":\"$(json_escape "${RUN_ID}")\","
    stats_payload+="\"telco\":\"$(json_escape "${CURRENT_TELCO}")\","
    stats_payload+="\"domains_total\":${TOTAL_LINES},"
    stats_payload+="\"domains_scanned\":${TOTAL_LINES},"
    stats_payload+="\"blocks_detected\":${TELCO_BLOCK_COUNT},"
    stats_payload+="\"duration_seconds\":${duration},"
    stats_payload+="\"started_at\":\"$(json_escape "${TELCO_STARTED_AT}")\","
    stats_payload+="\"ended_at\":\"$(json_escape "${TELCO_ENDED_AT}")\","
    stats_payload+="\"source_file\":\"$(json_escape "$(basename "${DOMAINS_FILE}")")\","
    stats_payload+="\"host_label\":\"$(json_escape "${HOST_LABEL}")\""
    stats_payload+="}"
    if api_post_json "/cron/domain-check-stats" "${stats_payload}" >/dev/null; then
        log "Posted per-telco stats for ${CURRENT_TELCO} (blocks=${TELCO_BLOCK_COUNT}, duration=${duration}s)."
    else
        log "WARN: failed to POST per-telco stats for ${CURRENT_TELCO}."
    fi

    # Append to SUMMARY_PER_TELCO (semicolon-separated triplets).
    SUMMARY_PER_TELCO="$(state_get SUMMARY_PER_TELCO)"
    new_entry="${CURRENT_TELCO}:${TELCO_BLOCK_COUNT}:${duration}"
    if [[ -z "${SUMMARY_PER_TELCO}" ]]; then
        SUMMARY_PER_TELCO="${new_entry}"
    else
        SUMMARY_PER_TELCO="${SUMMARY_PER_TELCO};${new_entry}"
    fi
    state_set SUMMARY_PER_TELCO "${SUMMARY_PER_TELCO}"

    NEXT_INDEX=$(( TELCO_INDEX + 1 ))
    if (( NEXT_INDEX < TOTAL_TELCOS )); then
        NEXT_TELCO="${CURRENT_TELCOS[${NEXT_INDEX}]}"
        sleep 3
        clear
        sleep 3
        log ""
        log "CHANGING TO NEXT TELCO ${NEXT_TELCO}. PLEASE WAIT $(( SWITCH_COOLDOWN_SECONDS / 60 ))MINS."
        state_set TELCO_INDEX     "${NEXT_INDEX}"
        state_set POINTER         "0"
        state_set ANNOUNCED_TELCO ""
        state_set SWITCH_UNTIL    "$(( $(date +%s) + SWITCH_COOLDOWN_SECONDS ))"
    else
        # All telcos done -> summary + archive.
        STARTED_AT="$(state_get STARTED_AT)"
        STARTED_EPOCH="$(date -d "${STARTED_AT}" +%s 2>/dev/null || echo "${NOW_EPOCH}")"
        TOTAL_DURATION=$(( TELCO_ENDED_EPOCH - STARTED_EPOCH ))

        # Aggregate unique blocked hosts across all telcos from REMARKS_FILE.
        TOTAL_BLOCKS=$(grep -c '^\[' "${REMARKS_FILE}" 2>/dev/null || echo 0)

        # Build telco_breakdown JSON array from SUMMARY_PER_TELCO.
        breakdown="["
        first=1
        IFS=';' read -r -a entries <<< "${SUMMARY_PER_TELCO}"
        for e in "${entries[@]}"; do
            [[ -z "${e}" ]] && continue
            IFS=':' read -r t b d <<< "${e}"
            entry_json="{\"telco\":\"$(json_escape "${t}")\",\"blocks_detected\":${b},\"duration_seconds\":${d}}"
            if (( first == 1 )); then
                breakdown+="${entry_json}"
                first=0
            else
                breakdown+=",${entry_json}"
            fi
        done
        breakdown+="]"

        summary_payload="{"
        summary_payload+="\"run_id\":\"$(json_escape "${RUN_ID}")\","
        summary_payload+="\"domains_total\":${TOTAL_LINES},"
        summary_payload+="\"domains_scanned\":${TOTAL_LINES},"
        summary_payload+="\"blocks_detected\":${TOTAL_BLOCKS},"
        summary_payload+="\"duration_seconds\":${TOTAL_DURATION},"
        summary_payload+="\"started_at\":\"$(json_escape "${STARTED_AT}")\","
        summary_payload+="\"ended_at\":\"$(json_escape "${TELCO_ENDED_AT}")\","
        summary_payload+="\"telco_breakdown\":${breakdown},"
        summary_payload+="\"source_file\":\"$(json_escape "$(basename "${DOMAINS_FILE}")")\","
        summary_payload+="\"host_label\":\"$(json_escape "${HOST_LABEL}")\""
        summary_payload+="}"
        if api_post_json "/cron/domain-check-summary" "${summary_payload}" >/dev/null; then
            sleep 3
            clear
            sleep 3
            log ""
            log "DONE CHECK AND SUMMARY STATISTIC SENT"
        else
            log "WARN: failed to POST summary. Archiving anyway; you can replay from state file."
        fi

        # Archive.
        archive_name="domains-$(date '+%Y%m%d-%H%M%S').txt"
        mv "${DOMAINS_FILE}" "${ARCHIVE_DIR}/${archive_name}"
        [[ -f "${REMARKS_FILE}" ]] && mv "${REMARKS_FILE}" "${ARCHIVE_DIR}/${archive_name}.remarks"
        [[ -f "${STATE_FILE}"   ]] && mv "${STATE_FILE}"   "${ARCHIVE_DIR}/${archive_name}.state"
        log "Archived to ${ARCHIVE_DIR}/${archive_name}"
    fi
else
    sleep 3
    clear
    sleep 3
    log ""
    log "CONTINUE NEXT BATCH. Pointer=${NEW_POINTER}/${TOTAL_LINES}."
fi
