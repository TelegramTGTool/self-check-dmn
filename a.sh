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

# 2b. Refresh this session's in-country DNS resolvers for FETCH_COUNTRY.
# Best-effort by design: a failure here must never stop the scan, because the
# recursive a.sh loop depends on check-domains.sh always being reached.
log "Running discover-resolvers.sh..."
bash "${SCRIPT_DIR}/discover-resolvers.sh" || log "discover-resolvers.sh failed. Continuing with existing DNS settings."

# 3. Run check-domains.sh
log "Running check-domains.sh..."
bash "${SCRIPT_DIR}/check-domains.sh"
