#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[a.sh] $*"; }

# 1. Pull latest changes
log "Pulling latest changes..."
git -C "${SCRIPT_DIR}" pull

# 2. Run check-domains.sh; if no active domain file, fetch first then retry
log "Running check-domains.sh..."
output="$(bash "${SCRIPT_DIR}/check-domains.sh" 2>&1)"
echo "${output}"

if echo "${output}" | grep -q "No active domain file"; then
    log "No domain file found. Running fetch-domains.sh..."
    bash "${SCRIPT_DIR}/fetch-domains.sh"
    log "Retrying check-domains.sh..."
    bash "${SCRIPT_DIR}/check-domains.sh"
fi
