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

log "Fetching active merchant domain list from ${API_BASE}/cron/domain-list"

tmp_file="${DOMAINS_FILE}.fetching.$$"
trap 'rm -f "${tmp_file}"' EXIT

if ! api_get_text "/cron/domain-list?format=text" > "${tmp_file}"; then
    die "API call failed (could not fetch domain list)."
fi

# Drop blank lines (avoid GNU sed -i; breaks on macOS BSD sed).
strip_blank_lines "${tmp_file}"
total="$(wc -l < "${tmp_file}" | tr -d ' ')"
if (( total == 0 )); then
    die "API returned 0 domains. Refusing to overwrite."
fi

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
