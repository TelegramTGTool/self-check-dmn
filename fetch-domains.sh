#!/usr/bin/env bash
#
# fetch-domains.sh
#
# Hourly cron: pulls the active-merchant domain list from dmnbot and
# writes it to ${WORK_DIR}/domains.active.txt for check-domains.sh to consume.
#
# IMPORTANT: if a previous run is still in progress (the active file exists or
# any telco still has work to do), this script does NOT overwrite the file.
#
# Recommended cron entry:
#   0 * * * *  /opt/domain-check/fetch-domains.sh >> /var/log/domain-check/fetch.log 2>&1

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_config

# Skip if work file is still in progress.
if [[ -f "${DOMAINS_FILE}" ]]; then
    DONE="$(state_get DONE)"
    if [[ "${DONE}" != "1" ]]; then
        log "Active domain file still in progress (${DOMAINS_FILE}). Skipping fetch."
        exit 0
    fi
    # If somehow flagged DONE but never archived, archive now.
    archive_name="domains-$(date '+%Y%m%d-%H%M%S').txt"
    mv "${DOMAINS_FILE}" "${ARCHIVE_DIR}/${archive_name}"
    [[ -f "${REMARKS_FILE}" ]] && mv "${REMARKS_FILE}" "${ARCHIVE_DIR}/${archive_name}.remarks"
    [[ -f "${STATE_FILE}"   ]] && mv "${STATE_FILE}"   "${ARCHIVE_DIR}/${archive_name}.state"
    log "Archived stale done-file as ${ARCHIVE_DIR}/${archive_name}"
fi

# FETCH_OFFSET/FETCH_LIMIT let multiple checker instances split one domain
# pool into disjoint ranges (e.g. instance A: FETCH_OFFSET=0 FETCH_LIMIT=300,
# instance B: FETCH_OFFSET=300 FETCH_LIMIT=300) so they never process the
# same batch concurrently. Each instance needs its own config.sh / WORK_DIR.
query="format=text&offset=${FETCH_OFFSET}"
[[ -n "${FETCH_LIMIT}" ]] && query+="&limit=${FETCH_LIMIT}"

log "Fetching active merchant domain list from ${API_BASE}/cron/domain-list?${query}"

tmp_file="${DOMAINS_FILE}.fetching.$$"
headers_file="${DOMAINS_FILE}.headers.$$"
trap 'rm -f "${tmp_file}" "${headers_file}"' EXIT

if ! api_get_text_with_headers "/cron/domain-list?${query}" "${headers_file}" > "${tmp_file}"; then
    die "API call failed (could not fetch domain list)."
fi

pool_total="$(awk -F': ' 'tolower($1)=="x-total-domains" { gsub(/\r/,"",$2); print $2; exit }' "${headers_file}" 2>/dev/null)"
rm -f "${headers_file}"

# Drop blank lines (avoid GNU sed -i; breaks on macOS BSD sed).
strip_blank_lines "${tmp_file}"
total="$(wc -l < "${tmp_file}" | tr -d ' ')"
if (( total == 0 )); then
    if [[ -n "${pool_total}" ]] && (( FETCH_OFFSET > 0 && FETCH_OFFSET >= pool_total )); then
        log "FETCH_OFFSET=${FETCH_OFFSET} is beyond the current pool (${pool_total} domains). Nothing to do for this instance. Skipping."
        exit 0
    fi
    die "API returned 0 domains. Refusing to overwrite."
fi

log "Fetched ${total} domains for this instance (offset=${FETCH_OFFSET}${FETCH_LIMIT:+, limit=${FETCH_LIMIT}}${pool_total:+, pool_total=${pool_total}})."

mv "${tmp_file}" "${DOMAINS_FILE}"
trap - EXIT

# Initialise fresh state.
run_id="$(date '+%Y%m%d%H%M%S')-$(printf '%04x' $((RANDOM * RANDOM % 65536)))"
: > "${STATE_FILE}"
state_set RUN_ID            "${run_id}"
state_set TOTAL_LINES       "${total}"
state_set TELCO_INDEX       "0"
state_set POINTER           "0"
state_set ANNOUNCED_TELCO   ""
state_set TELCO_BLOCK_COUNT "0"
state_set TELCO_LIST        "$(IFS=,; echo "${TELCO_LIST[*]}")"
state_set STARTED_AT        "$(date '+%Y-%m-%d %H:%M:%S')"
state_set TELCO_STARTED_AT  ""
state_set SUMMARY_PER_TELCO ""
state_set SWITCH_UNTIL      "0"
state_set DONE              "0"

# Reset remarks file for this run.
: > "${REMARKS_FILE}"
{
    echo "# Domain check remarks file"
    echo "# run_id=${run_id}"
    echo "# generated_at=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "# total_domains=${total}"
} >> "${REMARKS_FILE}"

log "Wrote ${total} domains to ${DOMAINS_FILE} (run_id=${run_id})"
