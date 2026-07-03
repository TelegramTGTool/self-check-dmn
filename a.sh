#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${SCRIPT_DIR}/data/domains.active.txt"

log() { echo "[a.sh] $*"; }

# 1. Pull latest changes
log "Pulling latest changes..."
if ! git -C "${SCRIPT_DIR}" pull; then
    clear
    sleep 1
    log "GIT PULL FAIL (possible no internet connection or GitHub issue). Aborting."
    exit 1
fi

# 2. If no domain file yet, fetch first
if [[ ! -f "${DOMAINS_FILE}" ]]; then
    log "No domain file found. Running fetch-domains.sh..."
    bash "${SCRIPT_DIR}/fetch-domains.sh"
fi

# 3. Run check-domains.sh
log "Running check-domains.sh..."
bash "${SCRIPT_DIR}/check-domains.sh"
