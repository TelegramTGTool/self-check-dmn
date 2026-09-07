#!/usr/bin/env bash
# Shared helpers for fetch-domains.sh and check-domains.sh.
# Sourced by both scripts; does not exit on its own.

set -u

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ----- Config loading ---------------------------------------------------------
# Maps FETCH_COUNTRY to its ISO 3166-1 alpha-2 code. Used for the DataImpulse
# __cr. target and for the country's resolver list. Empty when unknown.
country_iso() {
    local c
    c="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "${c}" in
        malaysia|my)          echo "my" ;;
        australia|au)         echo "au" ;;
        singapore|sg)         echo "sg" ;;
        indonesia|id)         echo "id" ;;
        thailand|th)          echo "th" ;;
        philippines|ph)       echo "ph" ;;
        vietnam|viet\ nam|vn) echo "vn" ;;
        india|in)             echo "in" ;;
        *)                    echo "" ;;
    esac
}

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
    : "${FETCH_OFFSET:=0}"
    : "${FETCH_LIMIT:=}"
    # Country pool this instance checks. Empty = let the API pick its default
    # (Malaysia). A checker probes from inside one country, so it must only be
    # handed the merchants registered for that country.
    : "${FETCH_COUNTRY:=}"
    : "${SWITCH_COOLDOWN_SECONDS:=1}"
    : "${HOST_LABEL:=$(hostname -s)}"
    : "${CURL_TIMEOUT:=15}"
    : "${CURL_MAX_REDIRECTS:=5}"
    : "${CURL_CONNECT_TIMEOUT:=${CURL_TIMEOUT}}"
    # Probes are HEAD requests; these codes mean "this server will not do HEAD",
    # so the probe retries once as GET with the body discarded.
    : "${HEAD_FALLBACK_CODES:=405 501}"
    # >0 enables the bounded inline-block-page body probe (bytes per domain).
    : "${BLOCK_BODY_PROBE_BYTES:=0}"
    : "${PING_COUNT:=2}"
    : "${PING_TIMEOUT:=2}"
    # Above 100 = disabled. Packet loss alone is not evidence of a block: CDNs
    # and firewalls drop ICMP wholesale, so every such host reads as blocked.
    # Ping's job is reading the resolved IP (regulator sinkhole detection).
    : "${PING_LOSS_BLOCK_THRESHOLD:=101}"
    : "${REPORT_BATCH_SIZE:=50}"

    # ---- Proxy mode (DataImpulse mobile gateway) ----------------------------
    # When enabled, every domain probe is sent through the proxy instead of the
    # box's own network, so "is this domain blocked in <country>" can be
    # answered without a physical SIM in that country.
    : "${PROXY_ENABLED:=0}"
    : "${PROXY_SCHEME:=http}"                    # http | socks5h
    : "${PROXY_HOST:=gw.dataimpulse.com}"
    : "${PROXY_PORT:=823}"
    : "${PROXY_USER:=}"
    : "${PROXY_PASS:=}"
    : "${PROXY_COUNTRY:=au}"                     # DataImpulse __cr.<code>
    : "${PROXY_CITY:=}"                          # DataImpulse __city.<name>
    : "${PROXY_ASN:=}"                           # DataImpulse __asn.<number>
    : "${PROXY_USER_SUFFIX:=}"                   # raw override for the __ params
    : "${PROXY_SESSION_MODE:=rotating}"          # rotating | sticky
    : "${PROXY_SESSION_TTL:=10}"                 # sticky session minutes
    : "${PROXY_SESSION_ID:=}"
    # A proxied probe pays for the gateway CONNECT, TLS to the target, every
    # redirect hop's TLS, and the body download. CURL_TIMEOUT (tuned for direct
    # probes off this box's own network) is far too tight for that chain, and a
    # transfer that overruns it reads as "timeout" on a perfectly healthy site.
    : "${PROXY_CONNECT_TIMEOUT:=10}"             # gateway/target connect phase
    : "${PROXY_CURL_TIMEOUT:=25}"                # whole transfer, redirects included
    : "${PROXY_MAX_RETRIES:=2}"                  # retries per domain before verdict
    : "${PROXY_UNREACHABLE_RESULT:=blocked}"     # blocked | unknown
    # HTTP status codes that count as a block when the probe goes through the
    # proxy. 451 is the explicit legal one; 403 is added because an ACMA-blocked
    # site answers the AU exit with a bare 403 while serving the same request
    # fine from anywhere else — measured 2026-09-07 across VODAFONE exits.
    # Space-separated; set to just "451" to restore the old behaviour.
    : "${PROXY_BLOCK_HTTP_CODES:=451 403}"

    # ---- Stage 1 in proxy mode: regulator DNS check --------------------------
    # MCMC enforces its blocklist at the Malaysian ISP resolvers, and the
    # DataImpulse gateway resolves names at its own infrastructure (Google DNS,
    # Singapore) BEFORE traffic reaches the Malaysian mobile exit. The block is
    # therefore invisible to a proxied fetch, no matter which ASN is targeted.
    # Measured 2026-09-06: 40 distinct exits across AS4818/9534/38466/10030 all
    # served the live site for a domain TM sinkholes to 175.139.142.25.
    #
    # So the resolver is queried separately from the transport: the name is
    # resolved from THIS host (which must sit on a Malaysian ISP) and matched
    # against MCMC_BLOCK_IPS, while the proxy still carries the HTTP probe with
    # its per-telco ASN targeting. Set PROXY_DNS_RESOLVER to pin a specific
    # resolver; empty uses the system one.
    : "${PROXY_LOCAL_DNS_CHECK:=1}"
    : "${PROXY_DNS_RESOLVER:=}"
    : "${PROXY_CONTROL_DOMAIN:=www.google.com}"  # must be reachable if proxy is healthy
    # Free ip-api tier is HTTP-only; the request just asks "what IP am I?", so
    # nothing sensitive travels in the clear. Any endpoint returning JSON with
    # countryCode / query / as keys works here.
    : "${PROXY_IP_CHECK_URL:=http://ip-api.com/json/?fields=status,countryCode,query,as}"
    : "${PROXY_VERIFY_COUNTRY:=1}"
    : "${PROXY_SWITCH_COOLDOWN_SECONDS:=5}"

    # Normalise truthy spellings so config.sh can say 1 / true / yes.
    case "$(printf '%s' "${PROXY_ENABLED}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) PROXY_ENABLED=1 ;;
        *)             PROXY_ENABLED=0 ;;
    esac

    if (( PROXY_ENABLED == 1 )); then
        [[ -n "${PROXY_USER}" ]] || die "PROXY_ENABLED=1 but PROXY_USER is empty (config.sh)."
        [[ -n "${PROXY_PASS}" ]] || die "PROXY_ENABLED=1 but PROXY_PASS is empty (config.sh)."
        # No SIM swap needed when the exit node is chosen by the gateway, so the
        # long manual switch cooldown does not apply.
        SWITCH_COOLDOWN_SECONDS="${PROXY_SWITCH_COOLDOWN_SECONDS}"
    fi

    # Extra DataImpulse targeting params per telco label, e.g.
    #   TELCO_PROXY_MAP=("TELSTRA=__asn.1221" "OPTUS=__asn.4804")
    # Empty by default: every telco then uses the plain country target.
    if [[ -z "${TELCO_PROXY_MAP+x}" ]]; then
        TELCO_PROXY_MAP=()
    fi

    if [[ -z "${TELCO_LIST+x}" || ${#TELCO_LIST[@]} -eq 0 ]]; then
        TELCO_LIST=(DIGI CELCOM HOTLINK UMOBILE UNIFI)
    fi

    # MCMC_PATTERNS / MCMC_BLOCK_IPS / BLOCK_PAGE_PATTERNS are normally defined
    # at the top of check-domains.sh (before load_config runs). Fall back to
    # safe defaults here so other callers (e.g. fetch-domains.sh) that don't
    # need them still work under `set -u`.
    if [[ -z "${MCMC_PATTERNS+x}" || ${#MCMC_PATTERNS[@]} -eq 0 ]]; then
        MCMC_PATTERNS=("skmm\\.gov\\.my" "mcmc")
    fi
    if [[ -z "${MCMC_BLOCK_IPS+x}" || ${#MCMC_BLOCK_IPS[@]} -eq 0 ]]; then
        MCMC_BLOCK_IPS=("175.139.142.25")
    fi
    if [[ -z "${BLOCK_PAGE_PATTERNS+x}" ]]; then
        BLOCK_PAGE_PATTERNS=()
    fi
    if [[ -z "${BLOCK_PAGE_URL_PATTERNS+x}" ]]; then
        BLOCK_PAGE_URL_PATTERNS=()
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

    # ---- Keep the proxy exit in the country being checked --------------------
    # FETCH_COUNTRY decides which merchants this instance is handed, so it also
    # decides which country the exit node must sit in. Leaving PROXY_COUNTRY on
    # a stale value asks DataImpulse for something impossible -- "__cr.my" with
    # an Australian ASN matches no exit at all, and the batch dies on the
    # pre-flight health check with the pointer untouched. Set
    # PROXY_COUNTRY_FOLLOWS_FETCH=0 to manage the two independently.
    : "${PROXY_COUNTRY_FOLLOWS_FETCH:=1}"
    if [[ "${PROXY_COUNTRY_FOLLOWS_FETCH}" == "1" && -n "${FETCH_COUNTRY}" ]]; then
        local _fetch_iso
        _fetch_iso="$(country_iso "${FETCH_COUNTRY}")"
        if [[ -n "${_fetch_iso}" && "${_fetch_iso}" != "${PROXY_COUNTRY}" ]]; then
            log "Proxy country '${PROXY_COUNTRY}' does not match FETCH_COUNTRY=${FETCH_COUNTRY}; targeting __cr.${_fetch_iso} instead."
            PROXY_COUNTRY="${_fetch_iso}"
        fi
    fi

    # ---- Session DNS resolvers (written by discover-resolvers.sh) ------------
    # In-country resolvers that were observed enforcing the regulator blocklist
    # this session, plus the sinkhole address(es) they hand out. Purely
    # additive: with no session file every value below keeps whatever config.sh
    # set, so the scan behaves exactly as it did before this feature existed.
    DNS_SESSION_FILE="${WORK_DIR}/resolvers.session"
    : "${DNS_SESSION_RESOLVERS:=}"
    : "${DNS_SESSION_SINKHOLES:=}"
    if [[ -f "${DNS_SESSION_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${DNS_SESSION_FILE}"
    fi
    if [[ -n "${DNS_SESSION_RESOLVERS}" ]]; then
        # Pin the first discovered resolver; resolve_host_ips_local() walks the
        # rest as fallbacks. An explicit PROXY_DNS_RESOLVER in config.sh wins.
        if [[ -z "${PROXY_DNS_RESOLVER}" ]]; then
            PROXY_DNS_RESOLVER="${DNS_SESSION_RESOLVERS%% *}"
        fi
        # A discovered in-country resolver makes the DNS stage meaningful on any
        # box, not just one physically on that country's ISP.
        PROXY_LOCAL_DNS_CHECK=1
        # Learned sinkholes join the configured ones; the verdict path itself is
        # untouched, it just has more addresses to match against.
        local _sink
        for _sink in ${DNS_SESSION_SINKHOLES}; do
            case " ${MCMC_BLOCK_IPS[*]+${MCMC_BLOCK_IPS[*]}} " in
                *" ${_sink} "*) ;;
                *) MCMC_BLOCK_IPS+=("${_sink}") ;;
            esac
        done
    fi
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

# Percent-encodes one query-string value (RFC 3986 unreserved set kept as-is).
url_encode() {
    # LC_ALL=C makes ${str:i:1} step one BYTE at a time, so a multi-byte
    # UTF-8 character encodes as its UTF-8 bytes rather than a codepoint.
    local str="$1" out="" i c LC_ALL=C
    for (( i = 0; i < ${#str}; i++ )); do
        c="${str:i:1}"
        case "${c}" in
            [a-zA-Z0-9.~_-]) out+="${c}" ;;
            *)               out+="$(printf '%%%02X' "'${c}")" ;;
        esac
    done
    printf '%s' "${out}"
}

# ----- HTTP helpers -----------------------------------------------------------
# NOTE: API calls always go out over the box's own network, never through the
# domain-check proxy — the dmnbot API may be a LAN/.test host the proxy cannot
# reach, and its responses must not depend on the exit country.
api_get_text() {
    local path="$1"
    curl -fsS \
        --max-time 60 \
        -H "X-CRON-KEY: ${CRON_API_KEY}" \
        "${API_BASE}${path}"
}

# Same as api_get_text, but also dumps response headers to ${2} (so callers
# can read informational headers like X-Total-Domains).
api_get_text_with_headers() {
    local path="$1"
    local headers_file="$2"
    curl -fsS \
        --max-time 60 \
        -D "${headers_file}" \
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

# Same as api_post_json, but retries on failure (network error, timeout, or
# non-2xx response) up to max_retries times with a short backoff between
# attempts. Prints the response body of the successful attempt on stdout.
api_post_json_retry() {
    local path="$1"
    local payload="$2"
    local timeout="${3:-60}"
    local max_retries="${4:-3}"
    local attempt=1 out
    while (( attempt <= max_retries )); do
        if out="$(api_post_json "${path}" "${payload}" "${timeout}")"; then
            printf '%s' "${out}"
            return 0
        fi
        if (( attempt < max_retries )); then
            log "WARN: POST ${path} failed (attempt ${attempt}/${max_retries}). Retrying in 5s."
            sleep 5
        fi
        attempt=$(( attempt + 1 ))
    done
    return 1
}

# ----- Proxy (DataImpulse mobile gateway) ------------------------------------
# DataImpulse takes its targeting options as `__key.value` suffixes appended to
# the plan username, e.g.
#     <login>__cr.au__asn.1221__sessid.9f3c__sesstime.10
# and authenticates on the shared gateway host/port (default gw.dataimpulse.com
# :823 for per-request rotation). Mobile is a separate plan with its own
# login/password on the same gateway — put those in PROXY_USER / PROXY_PASS.
#
# Globals set here:
#   PROXY_CURL_ARGS[]   curl flags to splice into every probe
#   PROXY_EXIT_IP / PROXY_EXIT_COUNTRY / PROXY_EXIT_ASN  (after proxy_probe_ip)

PROXY_CURL_ARGS=()
PROXY_EXIT_IP=""
PROXY_EXIT_COUNTRY=""
PROXY_EXIT_ASN=""

proxy_enabled() {
    [[ "${PROXY_ENABLED:-0}" == "1" ]]
}

# Extra `__` params configured for a telco label (empty when unmapped).
proxy_target_params() {
    local telco="$1" entry
    for entry in ${TELCO_PROXY_MAP[@]+"${TELCO_PROXY_MAP[@]}"}; do
        if [[ "${entry%%=*}" == "${telco}" ]]; then
            printf '%s' "${entry#*=}"
            return
        fi
    done
    printf ''
}

# Start a new sticky session id. Call on telco switch so each telco pass gets
# its own exit IP; harmless in rotating mode.
proxy_session_new() {
    PROXY_SESSION_ID="$(printf '%04x%04x' $(( RANDOM )) $(( RANDOM )))"
}

# Build the full gateway username (login + targeting params) for a telco.
proxy_build_user() {
    local telco="${1:-}"
    local user="${PROXY_USER}"

    if [[ -n "${PROXY_USER_SUFFIX}" ]]; then
        # Operator supplied the whole param string — use it verbatim.
        printf '%s%s' "${user}" "${PROXY_USER_SUFFIX}"
        return
    fi

    # Per-telco map entries win over the global defaults: a telco that pins its
    # own __asn / __city must not end up with both params in the username.
    local extra
    extra="$(proxy_target_params "${telco}")"

    [[ -n "${PROXY_COUNTRY}" && "${extra}" != *"__cr."*   ]] && user+="__cr.$(printf '%s' "${PROXY_COUNTRY}" | tr '[:upper:]' '[:lower:]')"
    [[ -n "${PROXY_CITY}"    && "${extra}" != *"__city."* ]] && user+="__city.$(printf '%s' "${PROXY_CITY}" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"
    [[ -n "${PROXY_ASN}"     && "${extra}" != *"__asn."*  ]] && user+="__asn.${PROXY_ASN}"

    [[ -n "${extra}" ]] && user+="${extra}"

    if [[ "${PROXY_SESSION_MODE}" == "sticky" ]]; then
        [[ -n "${PROXY_SESSION_ID}" ]] || proxy_session_new
        user+="__sessid.${PROXY_SESSION_ID}__sesstime.${PROXY_SESSION_TTL}"
    fi

    printf '%s' "${user}"
}

# Populate PROXY_CURL_ARGS for the given telco. No-op when proxy mode is off,
# so callers can always splice the array in unconditionally.
proxy_set_curl_args() {
    local telco="${1:-}"
    PROXY_CURL_ARGS=()
    proxy_enabled || return 0
    local user
    user="$(proxy_build_user "${telco}")"
    PROXY_CURL_ARGS=(
        --proxy "${PROXY_SCHEME}://${PROXY_HOST}:${PROXY_PORT}"
        --proxy-user "${user}:${PROXY_PASS}"
    )
    PROXY_USER_EFFECTIVE="${user}"
}

# Pull one "key":"value" string out of a flat JSON object (no jq needed).
json_str_field() {
    local body="$1" key="$2"
    printf '%s' "${body}" \
        | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -1
}

# Ask an IP echo service what the world sees. Sets PROXY_EXIT_*; returns
# non-zero if the request itself failed (proxy down / auth rejected).
#
# Parsed by key, not by line order: ip-api emits its fields in a FIXED
# documented order regardless of the order you list them in `fields=`, so
# positional parsing silently swaps `query` and `as`.
proxy_probe_ip() {
    local out rc
    out="$(curl -sS --max-time "$(( PROXY_CURL_TIMEOUT + 10 ))" \
        ${PROXY_CURL_ARGS[@]+"${PROXY_CURL_ARGS[@]}"} \
        "${PROXY_IP_CHECK_URL}" 2>/dev/null </dev/null)" && rc=0 || rc=$?
    (( rc == 0 )) || return "${rc}"

    local status
    status="$(json_str_field "${out}" "status")"
    if [[ -n "${status}" && "${status}" != "success" ]]; then
        return 1
    fi

    PROXY_EXIT_COUNTRY="$(json_str_field "${out}" "countryCode")"
    PROXY_EXIT_IP="$(json_str_field "${out}" "query")"
    PROXY_EXIT_ASN="$(json_str_field "${out}" "as")"
    # Common alternative key names (ipinfo.io etc.).
    [[ -z "${PROXY_EXIT_COUNTRY}" ]] && PROXY_EXIT_COUNTRY="$(json_str_field "${out}" "country")"
    [[ -z "${PROXY_EXIT_IP}"      ]] && PROXY_EXIT_IP="$(json_str_field "${out}" "ip")"
    [[ -z "${PROXY_EXIT_ASN}"     ]] && PROXY_EXIT_ASN="$(json_str_field "${out}" "org")"
    return 0
}

# Pre-flight before a batch: confirm the gateway works, report the exit node,
# and confirm a known-good control domain loads through it. Returns non-zero
# when the proxy itself is unhealthy — the caller should then skip the batch
# rather than record every domain as blocked.
proxy_health_check() {
    local telco="${1:-}"
    proxy_enabled || return 0

    proxy_set_curl_args "${telco}"

    if ! proxy_probe_ip; then
        log "WARN: proxy health check failed — could not reach ${PROXY_HOST}:${PROXY_PORT} (or auth rejected)."
        return 1
    fi

    log "Proxy exit node: ip=${PROXY_EXIT_IP} country=${PROXY_EXIT_COUNTRY} asn=${PROXY_EXIT_ASN:-?} target=${PROXY_USER_EFFECTIVE:-}"

    if [[ "${PROXY_VERIFY_COUNTRY}" == "1" && -n "${PROXY_COUNTRY}" ]]; then
        local want got
        want="$(printf '%s' "${PROXY_COUNTRY}" | tr '[:lower:]' '[:upper:]')"
        got="$(printf '%s' "${PROXY_EXIT_COUNTRY}" | tr '[:lower:]' '[:upper:]')"
        if [[ -z "${got}" ]]; then
            # The gateway answered, so it is up; we just could not read a
            # country back. Warn loudly rather than stalling the run forever.
            log "WARN: could not read exit country from ${PROXY_IP_CHECK_URL}. Continuing WITHOUT country verification."
        elif [[ "${want}" != "${got}" ]]; then
            log "WARN: proxy exited in ${got}, expected ${want}. Skipping batch to avoid wrong-country results."
            return 1
        fi
    fi

    local code rc
    code="$(curl -sS --connect-timeout "${PROXY_CONNECT_TIMEOUT}" \
        --max-time "${PROXY_CURL_TIMEOUT}" \
        --max-redirs "${CURL_MAX_REDIRECTS}" -L -o /dev/null -w '%{http_code}' \
        ${PROXY_CURL_ARGS[@]+"${PROXY_CURL_ARGS[@]}"} \
        "https://${PROXY_CONTROL_DOMAIN}/" 2>/dev/null </dev/null)" && rc=0 || rc=$?
    if (( rc != 0 )) || [[ -z "${code}" || "${code}" == "000" ]]; then
        log "WARN: control domain ${PROXY_CONTROL_DOMAIN} did not load through the proxy (curl rc=${rc}). Proxy session looks bad."
        return 1
    fi

    log "Proxy control check OK (${PROXY_CONTROL_DOMAIN} -> HTTP ${code})."
    return 0
}

# Does this name resolve from the box's own network? Used to tell a DNS-level
# block at the proxy exit (resolves here, not there) apart from a domain that is
# simply dead, expired or misspelled (resolves nowhere) — the two arrive as the
# same curl failure through the gateway but mean opposite things to a merchant.
# curl rc 6 is "could not resolve host", so no extra DNS tooling is required.
# Deliberately NOT proxied: the whole point is the comparison.
resolves_direct() {
    local host="$1" rc=0
    curl -sS -I \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_TIMEOUT}" \
        -o /dev/null "https://${host}/" >/dev/null 2>&1 </dev/null || rc=$?
    (( rc != 6 ))
}

# Turn a curl exit status (plus its stderr text) into a coarse failure class.
proxy_classify_failure() {
    local rc="$1" err="$2"
    case "${rc}" in
        0)     printf 'ok' ;;
        5|7)   printf 'proxy_error' ;;      # gateway host unresolvable / unreachable
        6)     printf 'dns_fail' ;;         # SOCKS: proxy could not resolve the target
        28)    printf 'timeout' ;;
        35|53|58|59|60|77) printf 'tls_fail' ;;
        52)    printf 'empty_reply' ;;
        56|97)
            if printf '%s' "${err}" | grep -qi '407'; then
                printf 'proxy_auth'
            elif printf '%s' "${err}" | grep -qiE 'tunnel failed, response 50[0-9]'; then
                printf 'upstream_fail'      # gateway reached, target did not answer
            elif printf '%s' "${err}" | grep -qiE 'tunnel failed, response 4[0-9][0-9]'; then
                printf 'proxy_denied'
            else
                printf 'conn_fail'
            fi
            ;;
        *)     printf 'conn_fail' ;;
    esac
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

# ----- Block-page matching ----------------------------------------------------
# Returns 0 (match) and sets BLOCK_MATCH_REASON / BLOCK_MATCH_PATTERN when the
# final URL or the response body looks like a regulator/ISP block page.
# URL-only block detection: a genuine block LANDS the probe on the regulator's
# page, so the final url after redirects is the evidence. Deliberately never
# matched against page bodies — that is what flagged every site whose own
# disclaimer happens to link to acma.gov.au.
match_block_url() {
    local final_url="$1"
    local pattern
    BLOCK_MATCH_REASON=""
    BLOCK_MATCH_PATTERN=""
    [[ -n "${final_url}" ]] || return 1

    for pattern in ${MCMC_PATTERNS[@]+"${MCMC_PATTERNS[@]}"}; do
        if printf '%s\n' "${final_url}" | grep -qiE "${pattern}"; then
            BLOCK_MATCH_REASON="mcmc_redirect"
            BLOCK_MATCH_PATTERN="${pattern}"
            return 0
        fi
    done

    for pattern in ${BLOCK_PAGE_URL_PATTERNS[@]+"${BLOCK_PAGE_URL_PATTERNS[@]}"}; do
        if printf '%s\n' "${final_url}" | grep -qiE "${pattern}"; then
            BLOCK_MATCH_REASON="block_page"
            BLOCK_MATCH_PATTERN="${pattern}"
            return 0
        fi
    done

    return 1
}

# Body wording scan, used only by the optional bounded inline-block probe.
# Host patterns (MCMC_PATTERNS, BLOCK_PAGE_URL_PATTERNS) are NOT applied here:
# a regulator's domain appearing somewhere in a page is not evidence the page
# IS that regulator's notice. Only distinctive block-page wording qualifies.
match_block_page() {
    local final_url="$1" body_file="$2"
    local pattern
    BLOCK_MATCH_REASON=""
    BLOCK_MATCH_PATTERN=""

    for pattern in ${BLOCK_PAGE_PATTERNS[@]+"${BLOCK_PAGE_PATTERNS[@]}"}; do
        if { [[ -n "${final_url}" ]] && printf '%s\n' "${final_url}" | grep -qiE "${pattern}"; } \
           || grep -qiE "${pattern}" "${body_file}" 2>/dev/null; then
            BLOCK_MATCH_REASON="block_page"
            BLOCK_MATCH_PATTERN="${pattern}"
            return 0
        fi
    done

    return 1
}

# ----- HTTP probe (headers only) ---------------------------------------------
# Follows redirects and reports the FINAL url + status WITHOUT downloading the
# page body. The domains under test are ~800 KB single-page casino fronts; a
# HEAD costs ~300 bytes, which is the difference between ~320 MB and ~120 KB
# per full pass. That matters on a metered SIM and on paid proxy bandwidth.
#
# Some WAFs answer HEAD with 405/501. Those retry once as GET with the body
# discarded, so a verdict never depends on the server supporting HEAD.
#
# Sets: PROBE_CODE PROBE_URL PROBE_RC PROBE_METHOD
http_probe() {
    local url="$1" connect_timeout="$2" timeout="$3" err_file="$4"
    shift 4
    local -a extra=("$@")
    local -a base=(
        -sS -L
        --connect-timeout "${connect_timeout}"
        --max-time "${timeout}"
        --max-redirs "${CURL_MAX_REDIRECTS}"
        -o /dev/null
        -w '%{http_code}|%{url_effective}'
    )
    local out rc

    PROBE_METHOD="HEAD"
    out="$(curl -I "${base[@]}" ${extra[@]+"${extra[@]}"} "${url}" 2>"${err_file}" </dev/null)" && rc=0 || rc=$?
    _http_probe_split "${out}"
    PROBE_RC="${rc}"

    if [[ " ${HEAD_FALLBACK_CODES} " == *" ${PROBE_CODE} "* ]]; then
        PROBE_METHOD="GET"
        out="$(curl "${base[@]}" ${extra[@]+"${extra[@]}"} "${url}" 2>"${err_file}" </dev/null)" && rc=0 || rc=$?
        _http_probe_split "${out}"
        PROBE_RC="${rc}"
    fi
}

_http_probe_split() {
    local out="$1"
    PROBE_CODE="${out%%|*}"
    PROBE_URL="${out#*|}"
    if [[ -z "${PROBE_CODE}" || "${PROBE_CODE}" == "${out}" ]]; then
        PROBE_CODE=0
        PROBE_URL=""
    fi
    PROBE_CODE="$(json_int "${PROBE_CODE}")"
}

# Optional inline-block-page probe. Some ISPs serve the notice at the ORIGINAL
# url with a 200 instead of redirecting, which a headers-only probe cannot see.
# When BLOCK_BODY_PROBE_BYTES > 0 this reads at most that many bytes (curl is
# killed by SIGPIPE once head has its quota, so the cap is real) and matches the
# wording patterns only. Off by default: it spends bandwidth on every clean
# domain to catch a case that most regulators do not use.
match_block_body_bounded() {
    local url="$1"
    shift
    local -a extra=("$@")
    local body_file hit=1

    (( BLOCK_BODY_PROBE_BYTES > 0 )) || return 1

    body_file="$(mktemp)"
    curl -sS -L \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_TIMEOUT}" \
        --max-redirs "${CURL_MAX_REDIRECTS}" \
        ${extra[@]+"${extra[@]}"} \
        "${url}" 2>/dev/null </dev/null \
        | head -c "${BLOCK_BODY_PROBE_BYTES}" > "${body_file}" || true

    match_block_page "" "${body_file}" && hit=0
    rm -f "${body_file}"
    return "${hit}"
}

# ----- Domain check (one host) ------------------------------------------------
# Sets globals: CHECK_RESULT (ok|blocked|unknown), CHECK_REASON, CHECK_EVIDENCE,
# CHECK_LOSS_PCT, CHECK_HTTP_CODE
#
# Both modes run the same two stages; only the transport differs.
#
#   direct (PROXY_ENABLED=0, real SIM / real mobile data — Malaysia)
#     1. ICMP ping to read the RESOLVED IP. A regulator DNS redirect lands on a
#        known sinkhole (MCMC_BLOCK_IPS) -> blocked.
#     2. Headers-only HTTPS probe following redirects. Final url on a regulator
#        block page -> blocked. Redirected anywhere else, or not redirected at
#        all -> not blocked.
#
#   proxy (PROXY_ENABLED=1, DataImpulse mobile gateway — Australia)
#     Stage 1 does not exist: ICMP cannot traverse an HTTP/SOCKS proxy, and a
#     proxied request reports the GATEWAY's peer address, never the target's
#     resolved IP. The equivalent AU signal is the exit node failing to resolve
#     the host at all, which surfaces as a curl failure class below.
#     Stage 2 is the same headers-only probe, sent through the gateway.
check_one_domain() {
    local host="$1"
    local telco="${2:-}"
    # Strip scheme and any trailing path so ping/curl receive a bare host.
    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    CHECK_RESULT="ok"
    CHECK_REASON=""
    CHECK_EVIDENCE=""
    CHECK_LOSS_PCT=0
    CHECK_HTTP_CODE=0

    if proxy_enabled; then
        check_one_domain_via_proxy "${host}" "${telco}"
        return
    fi

    # ---- Stage 1: ICMP — resolved IP only.
    # macOS: -W is wait per reply in MILLISECONDS (not seconds like GNU ping on Linux).
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

    # Resolved IP is on the first "PING host (1.2.3.4)..." line. A regulator DNS
    # redirect points the name at a sinkhole, so this is the real signal.
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

    # Packet loss is NOT evidence of a block on its own — CDNs and firewalls
    # drop ICMP wholesale, and every such host would read as blocked. Kept as an
    # opt-in: set PING_LOSS_BLOCK_THRESHOLD to 100 or less to restore it.
    if (( PING_LOSS_BLOCK_THRESHOLD <= 100 )) && (( loss >= PING_LOSS_BLOCK_THRESHOLD )); then
        CHECK_RESULT="blocked"
        CHECK_REASON="ping_loss"
        CHECK_EVIDENCE="loss=${loss}%"
        return
    fi

    # ---- Stage 2: headers-only HTTPS probe, redirects followed.
    local err_file
    err_file="$(mktemp)"
    http_probe "https://${host}/" "${CURL_CONNECT_TIMEOUT}" "${CURL_TIMEOUT}" "${err_file}"
    rm -f "${err_file}"
    CHECK_HTTP_CODE="${PROBE_CODE}"

    if match_block_url "${PROBE_URL}"; then
        CHECK_RESULT="blocked"
        CHECK_REASON="${BLOCK_MATCH_REASON}"
        CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} pat=${BLOCK_MATCH_PATTERN}"
        return
    fi

    if (( PROBE_CODE == 451 )); then
        CHECK_RESULT="blocked"
        CHECK_REASON="http_451"
        CHECK_EVIDENCE="code=451 url=${PROBE_URL}"
        return
    fi

    if match_block_body_bounded "https://${host}/"; then
        CHECK_RESULT="blocked"
        CHECK_REASON="${BLOCK_MATCH_REASON}"
        CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} pat=${BLOCK_MATCH_PATTERN} inline"
        return
    fi

    if (( PROBE_CODE == 0 )); then
        CHECK_RESULT="unknown"
        CHECK_REASON="http_error"
        CHECK_EVIDENCE="curl_failed rc=${PROBE_RC}"
        return
    fi

    CHECK_RESULT="ok"
    CHECK_REASON="ok"
    CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} method=${PROBE_METHOD}"
}

# True when the status code is one PROXY_BLOCK_HTTP_CODES calls a block.
# Sets PROXY_BLOCK_CODE_REASON to the reason string for the log line.
proxy_code_is_block() {
    local code="$1" want
    PROXY_BLOCK_CODE_REASON=""
    for want in ${PROXY_BLOCK_HTTP_CODES}; do
        if [[ "${code}" == "${want}" ]]; then
            PROXY_BLOCK_CODE_REASON="http_${code}"
            return 0
        fi
    done
    return 1
}

# Resolve a host to its A records from THIS machine, not through the proxy.
# Used for the regulator-DNS stage in proxy mode: the sinkhole answer only
# exists on a Malaysian ISP resolver, and the gateway never consults one.
# Prints one IPv4 per line; empty output means "could not resolve".
# Resolve <host> at ONE resolver. Empty resolver = this box's system resolver,
# which is exactly what resolve_host_ips_local() did before session resolvers
# existed.
_resolve_host_ips_at() {
    local host="$1"
    local resolver="${2:-}"
    local -a server=()
    [[ -n "${resolver}" ]] && server=("@${resolver}")

    if command -v dig >/dev/null 2>&1; then
        dig +short +time=3 +tries=1 "${host}" ${server[@]+"${server[@]}"} 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
        return 0
    fi
    if command -v host >/dev/null 2>&1; then
        host -W 3 -t A "${host}" ${resolver:+"${resolver}"} 2>/dev/null \
            | sed -n 's/.*has address \([0-9.]*\).*/\1/p' || true
        return 0
    fi
    getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u || true
    return 0
}

resolve_host_ips_local() {
    local host="$1"
    # Walk this session's in-country resolvers first and take the first one that
    # answers. A public resolver dying mid-scan would otherwise turn every
    # remaining blocked domain into a silent "ok".
    local _r _out
    for _r in ${DNS_SESSION_RESOLVERS:-}; do
        _out="$(_resolve_host_ips_at "${host}" "${_r}")"
        if [[ -n "${_out}" ]]; then
            printf '%s\n' "${_out}"
            return 0
        fi
    done
    _resolve_host_ips_at "${host}" "${PROXY_DNS_RESOLVER}"
}

# Probe one host through the proxy. Sets the same CHECK_* globals.
#
# Verdict rules:
#   * name resolves to a regulator sinkhole
#     (checked on the LOCAL resolver, not
#     through the gateway)                  -> blocked
#   * final url on a regulator block page   -> blocked
#   * status in PROXY_BLOCK_HTTP_CODES
#     (451 legal block, 403 = the ACMA
#     pattern: refused to the AU exit only) -> blocked
#   * DNS / TLS / connection failure at the
#     exit node                             -> blocked (per PROXY_UNREACHABLE_RESULT)
#   * any real HTTP status from the target  -> ok (it answered)
#   * gateway itself failing (auth, 407,
#     unreachable)                          -> unknown, never blocked
check_one_domain_via_proxy() {
    local host="$1"
    local telco="${2:-}"
    local attempt=1 max_attempts=$(( PROXY_MAX_RETRIES + 1 ))
    local err_file class

    # ICMP cannot be proxied; there is no packet-loss figure in this mode.
    CHECK_LOSS_PCT=0

    # ---- Stage 1: regulator DNS, resolved locally (see load_config notes).
    # Deliberately NOT sent through the gateway: the gateway resolves in
    # Singapore and would never see the sinkhole. A hit here is authoritative —
    # a name pointed at a regulator sinkhole is blocked regardless of what the
    # proxied fetch returns, and the proxied fetch WILL return the live site.
    if [[ "${PROXY_LOCAL_DNS_CHECK}" == "1" ]]; then
        local rip block_ip
        while read -r rip; do
            [[ -n "${rip}" ]] || continue
            for block_ip in ${MCMC_BLOCK_IPS[@]+"${MCMC_BLOCK_IPS[@]}"}; do
                if [[ "${rip}" == "${block_ip}" ]]; then
                    CHECK_RESULT="blocked"
                    CHECK_REASON="mcmc_block_ip"
                    CHECK_EVIDENCE="ip=${rip} dns=local:${PROXY_DNS_RESOLVER:-system} telco=${telco:-?}"
                    return
                fi
            done
        done < <(resolve_host_ips_local "${host}")
    fi

    while (( attempt <= max_attempts )); do
        # Rebuild args each attempt: in rotating mode this draws a fresh exit
        # IP, so one bad mobile node does not become a false "blocked".
        if [[ "${PROXY_SESSION_MODE}" != "sticky" ]] && (( attempt > 1 )); then
            proxy_session_new
        fi
        proxy_set_curl_args "${telco}"

        err_file="$(mktemp)"
        http_probe "https://${host}/" "${PROXY_CONNECT_TIMEOUT}" "${PROXY_CURL_TIMEOUT}" \
            "${err_file}" ${PROXY_CURL_ARGS[@]+"${PROXY_CURL_ARGS[@]}"}
        CHECK_HTTP_CODE="${PROBE_CODE}"
        class="$(proxy_classify_failure "${PROBE_RC}" "$(cat "${err_file}" 2>/dev/null)")"
        rm -f "${err_file}"

        if match_block_url "${PROBE_URL}"; then
            CHECK_RESULT="blocked"
            CHECK_REASON="${BLOCK_MATCH_REASON}"
            CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} pat=${BLOCK_MATCH_PATTERN} exit_ip=${PROXY_EXIT_IP:-?} cc=${PROXY_EXIT_COUNTRY:-${PROXY_COUNTRY}}"
            return
        fi

        if [[ "${class}" == "ok" ]]; then
            if proxy_code_is_block "${PROBE_CODE}"; then
                CHECK_RESULT="blocked"
                CHECK_REASON="${PROXY_BLOCK_CODE_REASON}"
                CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} method=${PROBE_METHOD} cc=${PROXY_EXIT_COUNTRY:-${PROXY_COUNTRY}} exit_ip=${PROXY_EXIT_IP:-?}"
                return
            fi

            if match_block_body_bounded "https://${host}/" ${PROXY_CURL_ARGS[@]+"${PROXY_CURL_ARGS[@]}"}; then
                CHECK_RESULT="blocked"
                CHECK_REASON="${BLOCK_MATCH_REASON}"
                CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} pat=${BLOCK_MATCH_PATTERN} inline cc=${PROXY_EXIT_COUNTRY:-${PROXY_COUNTRY}}"
                return
            fi

            CHECK_RESULT="ok"
            CHECK_REASON="ok"
            CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} method=${PROBE_METHOD} via=proxy cc=${PROXY_EXIT_COUNTRY:-${PROXY_COUNTRY}}"
            return
        fi

        # curl received a real status line before the transfer broke off, so the
        # domain resolved, connected and answered — it simply did not finish
        # inside PROXY_CURL_TIMEOUT. A host that answers is not blocked,
        # whatever the curl rc says.
        if (( PROBE_CODE >= 100 )); then
            # ...unless the status it did send is itself a block verdict.
            if proxy_code_is_block "${PROBE_CODE}"; then
                CHECK_RESULT="blocked"
                CHECK_REASON="${PROXY_BLOCK_CODE_REASON}"
                CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} partial=${class} cc=${PROXY_EXIT_COUNTRY:-${PROXY_COUNTRY}} exit_ip=${PROXY_EXIT_IP:-?}"
                return
            fi
            CHECK_RESULT="ok"
            CHECK_REASON="ok"
            CHECK_EVIDENCE="code=${PROBE_CODE} url=${PROBE_URL} partial=${class} curl_rc=${PROBE_RC} cc=${PROXY_EXIT_COUNTRY:-${PROXY_COUNTRY}}"
            return
        fi

        # The gateway itself is at fault — never blame the domain for that.
        case "${class}" in
            proxy_error|proxy_auth|proxy_denied)
                CHECK_RESULT="unknown"
                CHECK_REASON="proxy_error"
                CHECK_EVIDENCE="class=${class} curl_rc=${PROBE_RC} gw=${PROXY_HOST}:${PROXY_PORT}"
                return
                ;;
        esac

        if (( attempt < max_attempts )); then
            attempt=$(( attempt + 1 ))
            continue
        fi

        # Out of retries: the failure looks like it belongs to the domain. On a
        # SOCKS gateway a target the exit node cannot resolve is exactly how a
        # DNS-level block presents itself.
        case "${class}" in
            dns_fail)
                CHECK_RESULT="${PROXY_UNREACHABLE_RESULT}"
                # Resolves from here but not through the exit node = the exit's
                # resolver is blocking it. Resolves nowhere = dead domain.
                if resolves_direct "${host}"; then
                    CHECK_REASON="dns_block"
                else
                    CHECK_REASON="dns_invalid"
                fi
                ;;
            tls_fail)
                CHECK_RESULT="${PROXY_UNREACHABLE_RESULT}"
                CHECK_REASON="tls_reset"
                ;;
            empty_reply|conn_fail)
                CHECK_RESULT="${PROXY_UNREACHABLE_RESULT}"
                CHECK_REASON="connection_reset"
                ;;
            upstream_fail)
                CHECK_RESULT="${PROXY_UNREACHABLE_RESULT}"
                CHECK_REASON="unreachable"
                ;;
            timeout)
                CHECK_RESULT="${PROXY_UNREACHABLE_RESULT}"
                CHECK_REASON="timeout"
                ;;
            *)
                CHECK_RESULT="unknown"
                CHECK_REASON="proxy_error"
                ;;
        esac
        CHECK_EVIDENCE="class=${class} curl_rc=${PROBE_RC} attempts=${max_attempts} exit_cc=${PROXY_EXIT_COUNTRY:-${PROXY_COUNTRY}}"
        return
    done
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
# curl reports %{http_code} zero-padded, and "000" when no HTTP response ever
# arrived (DNS failure, TLS reset, proxy timeout). JSON forbids leading zeros,
# so embedding such a value raw yields a body the API cannot decode. Normalise
# any numeric-ish value to a bare JSON integer.
json_int() {
    local s="${1:-}"
    s="${s//[^0-9]/}"
    printf '%s' "$(( 10#${s:-0} ))"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
