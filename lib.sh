#!/usr/bin/env bash
# Shared helpers for fetch-domains.sh and check-domains.sh.
# Sourced by both scripts; does not exit on its own.

set -u

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ----- Config loading ---------------------------------------------------------
load_config() {
    local cfg="${SCRIPT_DIR}/config.sh"
    if [[ ! -f "${cfg}" ]]; then
        echo "[FATAL] Missing ${cfg}. Copy config.sh.example and edit it." >&2
        exit 2
    fi
    # shellcheck disable=SC1090
    source "${cfg}"

    : "${API_BASE:?API_BASE not set}"
    : "${CRON_API_KEY:?CRON_API_KEY not set}"
    # Default to script-local dirs (macOS / dev). Production can set /var/lib/... in config.sh.
    : "${WORK_DIR:=${SCRIPT_DIR}/data}"
    : "${ARCHIVE_DIR:=${WORK_DIR}/archive}"
    : "${LOG_DIR:=${SCRIPT_DIR}/logs}"
    : "${BATCH_SIZE:=100}"
    : "${SWITCH_COOLDOWN_SECONDS:=1}"
    : "${HOST_LABEL:=$(hostname -s)}"
    : "${CURL_TIMEOUT:=15}"
    : "${CURL_MAX_REDIRECTS:=5}"
    : "${PING_COUNT:=2}"
    : "${PING_TIMEOUT:=2}"
    : "${PING_LOSS_BLOCK_THRESHOLD:=100}"
    : "${REPORT_BATCH_SIZE:=50}"

    if [[ -z "${TELCO_LIST+x}" || ${#TELCO_LIST[@]} -eq 0 ]]; then
        TELCO_LIST=(DIGI CELCOM HOTLINK UMOBILE UNIFI)
    fi

    # MCMC_PATTERNS / MCMC_BLOCK_IPS are normally defined at the top of
    # check-domains.sh (before load_config runs). Fall back to safe defaults
    # here so other callers (e.g. fetch-domains.sh) that don't need them
    # still work under `set -u`.
    if [[ -z "${MCMC_PATTERNS+x}" || ${#MCMC_PATTERNS[@]} -eq 0 ]]; then
        MCMC_PATTERNS=("skmm\\.gov\\.my" "mcmc")
    fi
    if [[ -z "${MCMC_BLOCK_IPS+x}" || ${#MCMC_BLOCK_IPS[@]} -eq 0 ]]; then
        MCMC_BLOCK_IPS=("175.139.142.25")
    fi

    if ! mkdir -p "${WORK_DIR}" "${ARCHIVE_DIR}" "${LOG_DIR}" 2>/dev/null; then
        # e.g. config still points at /var/lib/... without sudo on macOS
        WORK_DIR="${SCRIPT_DIR}/data"
        ARCHIVE_DIR="${WORK_DIR}/archive"
        LOG_DIR="${SCRIPT_DIR}/logs"
        if ! mkdir -p "${WORK_DIR}" "${ARCHIVE_DIR}" "${LOG_DIR}"; then
            die "Cannot create work directories under ${SCRIPT_DIR}/data (check permissions)."
        fi
        log "Using local data dir ${WORK_DIR} (configured path was not writable)."
    fi

    DOMAINS_FILE="${WORK_DIR}/domains.active.txt"
    STATE_FILE="${WORK_DIR}/domains.active.txt.state"
    REMARKS_FILE="${WORK_DIR}/domains.active.txt.remarks"
    LOCK_FILE="${WORK_DIR}/domains.active.txt.lock"
}

# Remove empty / whitespace-only lines (portable; no sed -i).
strip_blank_lines() {
    local f="$1"
    local cleaned="${f}.clean.$$"
    grep -vE '^[[:space:]]*$' "${f}" > "${cleaned}" || : > "${cleaned}"
    mv "${cleaned}" "${f}"
}

# ----- Logging ----------------------------------------------------------------
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] $*"
}

die() {
    log "[FATAL] $*"
    exit 1
}

# ----- State (key=value file) -------------------------------------------------
state_get() {
    local key="$1"
    [[ -f "${STATE_FILE}" ]] || { echo ""; return; }
    awk -F= -v k="${key}" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "${STATE_FILE}"
}

state_set() {
    local key="$1"
    local value="$2"
    local tmp="${STATE_FILE}.tmp.$$"
    if [[ ! -f "${STATE_FILE}" ]]; then
        printf '%s=%s\n' "${key}" "${value}" > "${STATE_FILE}"
        return
    fi
    awk -F= -v k="${key}" -v v="${value}" '
        BEGIN { found=0 }
        $1==k { print k"="v; found=1; next }
        { print }
        END { if (!found) print k"="v }
    ' "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}"
}

# ----- HTTP helpers -----------------------------------------------------------
api_get_text() {
    local path="$1"
    curl -fsS \
        --max-time 60 \
        -H "X-CRON-KEY: ${CRON_API_KEY}" \
        "${API_BASE}${path}"
}

api_post_json() {
    local path="$1"
    local payload="$2"
    local timeout="${3:-60}"
    curl -fsS \
        --max-time "${timeout}" \
        -H "X-CRON-KEY: ${CRON_API_KEY}" \
        -H 'Content-Type: application/json' \
        -X POST \
        --data-binary "${payload}" \
        "${API_BASE}${path}"
}

# ----- Lock (mkdir + pid; works on macOS and Linux without flock) -------------
release_lock() {
    rm -rf "${LOCK_FILE}.dir"
    # Legacy file from older flock-based lock.
    [[ -f "${LOCK_FILE}" ]] && rm -f "${LOCK_FILE}"
}

acquire_lock() {
    local lock_dir="${LOCK_FILE}.dir"

    _lock_take() {
        mkdir "${lock_dir}" 2>/dev/null || return 1
        echo $$ > "${lock_dir}/pid"
        trap release_lock EXIT
        return 0
    }

    if _lock_take; then
        return 0
    fi

    local pid=""
    [[ -f "${lock_dir}/pid" ]] && pid="$(<"${lock_dir}/pid")"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        log "Another check-domains run is in progress (pid=${pid}). Exiting."
        exit 0
    fi

    rm -rf "${lock_dir}"
    if _lock_take; then
        log "Removed stale lock; continuing."
        return 0
    fi

    log "Another check-domains run is in progress (lock held). Exiting."
    exit 0
}

# ----- Domain check (one host) ------------------------------------------------
# Sets globals: CHECK_RESULT (ok|blocked|unknown), CHECK_REASON, CHECK_EVIDENCE,
# CHECK_LOSS_PCT, CHECK_HTTP_CODE
check_one_domain() {
    local host="$1"
    # Strip scheme and any trailing path so ping/curl receive a bare host.
    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    CHECK_RESULT="ok"
    CHECK_REASON=""
    CHECK_EVIDENCE=""
    CHECK_LOSS_PCT=0
    CHECK_HTTP_CODE=0

    # ---- Step 1: ICMP ping
    # macOS: -W is wait per reply in MILLISECONDS (not seconds like GNU ping on Linux).
    # Linux: -W is typically seconds to wait for each reply.
    local ping_out loss
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local ping_wait_ms=$(( PING_TIMEOUT * 1000 ))
        ping_out="$(ping -c "${PING_COUNT}" -W "${ping_wait_ms}" -- "${host}" 2>&1 || true)"
    else
        ping_out="$(ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" -- "${host}" 2>&1 || true)"
    fi
    loss="$(printf '%s\n' "${ping_out}" | sed -n 's/.*\([0-9][0-9.]*\)% packet loss.*/\1/p' | head -1)"
    if [[ -z "${loss}" ]]; then
        loss=100
    else
        loss="$(printf '%.0f' "${loss}" 2>/dev/null || echo 100)"
    fi
    CHECK_LOSS_PCT="${loss}"

    # Resolved IP is on the first "PING host (1.2.3.4)..." line. If it lands on a
    # known MCMC sinkhole IP, flag it regardless of packet loss.
    local resolved_ip block_ip
    resolved_ip="$(printf '%s\n' "${ping_out}" | sed -n '1s/.*(\([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\)).*/\1/p')"
    if [[ -n "${resolved_ip}" ]]; then
        for block_ip in "${MCMC_BLOCK_IPS[@]}"; do
            if [[ "${resolved_ip}" == "${block_ip}" ]]; then
                CHECK_RESULT="blocked"
                CHECK_REASON="mcmc_block_ip"
                CHECK_EVIDENCE="ip=${resolved_ip}"
                return
            fi
        done
    fi

    if (( loss >= PING_LOSS_BLOCK_THRESHOLD )); then
        CHECK_RESULT="blocked"
        CHECK_REASON="ping_loss"
        CHECK_EVIDENCE="loss=${loss}%"
        return
    fi

    # ---- Step 2: HTTPS probe only
    local http_out code final_url body_file
    body_file="$(mktemp)"
    http_out="$(curl -sS \
        --max-time "${CURL_TIMEOUT}" \
        --max-redirs "${CURL_MAX_REDIRECTS}" \
        -L \
        -o "${body_file}" \
        -w '%{http_code}|%{url_effective}' \
        "https://${host}/" 2>/dev/null || true)"

    code="${http_out%%|*}"
    final_url="${http_out#*|}"
    if [[ -z "${code}" || "${code}" == "${http_out}" ]]; then
        code=0
        final_url=""
    fi
    CHECK_HTTP_CODE="${code}"

    # MCMC pattern match against final URL OR response body (grep -i: Bash 3.2 safe on macOS).
    local pattern hit=0
    for pattern in "${MCMC_PATTERNS[@]}"; do
        if { [[ -n "${final_url}" ]] && printf '%s\n' "${final_url}" | grep -qiE "${pattern}"; } \
           || grep -qiE "${pattern}" "${body_file}" 2>/dev/null; then
            hit=1
            break
        fi
    done
    rm -f "${body_file}"

    if (( hit == 1 )); then
        CHECK_RESULT="blocked"
        CHECK_REASON="mcmc_redirect"
        CHECK_EVIDENCE="code=${code} url=${final_url}"
        return
    fi

    if (( 10#${code:-0} == 0 )); then
        CHECK_RESULT="unknown"
        CHECK_REASON="http_error"
        CHECK_EVIDENCE="curl_failed"
        return
    fi

    CHECK_RESULT="ok"
    CHECK_REASON="ok"
    CHECK_EVIDENCE="code=${code}"
}

# ----- Build JSON array of {"merchant_id":N,"domain":"host"} from a
# "merchant_id|host" lines file (e.g. the active domains file for a
# just-completed telco run). -------------------------------------------------
build_domains_json() {
    local file="$1"
    local -a entries=()
    local merchant_id host
    while IFS='|' read -r merchant_id host; do
        [[ -z "${host}" ]] && continue
        entries+=("{\"merchant_id\":${merchant_id},\"domain\":\"$(json_escape "${host}")\"}")
    done < "${file}"
    local IFS=,
    echo "[${entries[*]:-}]"
}

# ----- JSON helper (no jq required) ------------------------------------------
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
