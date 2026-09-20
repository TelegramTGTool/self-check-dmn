#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${SCRIPT_DIR}/data/domains.active.txt"

log() { echo "[a.sh] $*"; }
clear
sleep 3
log ""
# 1. Pull latest changes
log "Pulling latest changes..."
if ! git -C "${SCRIPT_DIR}" pull; then
    sleep 3
    clear
    sleep 3
    log ""
    log "GIT PULL FAIL (possible no internet connection or GitHub issue). Aborting."
    exit 1
fi

# 2. If no domain file yet, fetch first
if [[ ! -f "${DOMAINS_FILE}" ]]; then
    log "No domain file found. Running fetch-domains.sh..."
    bash "${SCRIPT_DIR}/fetch-domains.sh"
fi

# 2a. Nothing to scan? Then the two DNS stages below have nothing to prepare.
# fetch-domains.sh refuses to overwrite on an empty API response, so a country
# whose pool comes back with 0 domains leaves no file at all -- and both steps
# below would still run anyway: discovery falls back to the last ARCHIVED list
# and spends minutes sweeping that country's resolvers, then dnscheck.py gets
# up to DNSCHECK_REFRESH_TIMEOUT more. Minutes of work to prepare a scan that
# cannot happen, every cycle, for as long as the pool stays empty.
#
# check-domains.sh is still reached either way -- it reports the missing file
# and exits 0 -- because the recursive a.sh loop depends on that.
if [[ ! -s "${DOMAINS_FILE}" ]]; then
    log "No domains to scan. Skipping the DNS refresh steps."
else

    # 2b. Refresh this session's in-country DNS resolvers for FETCH_COUNTRY.
    # Best-effort by design: a failure here must never stop the scan, because the
    # recursive a.sh loop depends on check-domains.sh always being reached.
    log "Running discover-resolvers.sh..."
    bash "${SCRIPT_DIR}/discover-resolvers.sh" || log "discover-resolvers.sh failed. Continuing with existing DNS settings."

    # 2c. Refresh .dnscheck.json so the standalone checkers never match on a stale
    # sinkhole. The AU sinkholes are Azure addresses behind block.acma.gov.au and
    # block.teqsa.gov.au, published with 15-60 minute TTLs, so the address really
    # does move; a cached one silently turns a "blocked" verdict into "ok".
    #
    # No --refresh here: dnscheck.py now re-derives the sinkholes from live answers
    # on every run and rewrites the cache when they differ, which is the freshness
    # we want for ~10s. --refresh additionally re-sweeps 200 candidate resolvers per
    # country (~4 min) and is only worth it by hand. The timeout still allows for
    # that, because dnscheck.py falls back to a full sweep by itself once the known
    # resolvers stop enforcing.
    #
    # Same doctrine as discover-resolvers.sh above -- best-effort AND time-boxed,
    # because the recursive a.sh loop depends on check-domains.sh always being
    # reached.
    : "${DNSCHECK_REFRESH_TIMEOUT:=600}"

    # macOS ships no timeout(1), so bound the run with a watchdog child instead.
    run_bounded() {                      # run_bounded <seconds> <cmd> [args...]
        local secs="$1"; shift
        "$@" &
        local pid=$!
        ( sleep "${secs}"; kill -TERM "${pid}" 2>/dev/null ) >/dev/null 2>&1 &
        local watchdog=$!
        local rc=0
        wait "${pid}" 2>/dev/null || rc=$?
        kill -TERM "${watchdog}" 2>/dev/null
        wait "${watchdog}" 2>/dev/null || :
        return "${rc}"
    }

    if ! command -v python3 >/dev/null 2>&1; then
        log "python3 not found. Skipping .dnscheck.json refresh."
    elif run_bounded "${DNSCHECK_REFRESH_TIMEOUT}" \
            python3 "${SCRIPT_DIR}/dnscheck.py"; then
        log ".dnscheck.json refreshed."
    else
        log "dnscheck.py refresh failed or exceeded ${DNSCHECK_REFRESH_TIMEOUT}s. Keeping the previous .dnscheck.json."
    fi
fi

# 3. Run check-domains.sh
log "Running check-domains.sh..."
bash "${SCRIPT_DIR}/check-domains.sh"
