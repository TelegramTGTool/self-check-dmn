#!/usr/bin/env bash
#
# discover-resolvers.sh
#
# Finds DNS resolvers INSIDE the country named by FETCH_COUNTRY that actually
# enforce that country's regulator blocklist, and learns the regulator's
# sinkhole IP(s) automatically. Results are written to a session file that
# lib.sh picks up, so nothing about the resolver or the sinkhole is hard-coded.
#
# Why this exists: the regulators block at the ISP's own recursive resolver.
# The DataImpulse gateway resolves names at its own infrastructure long before
# traffic reaches the mobile exit, so a proxied fetch sees the live site even
# for a sinkholed domain. Asking an in-country resolver directly is both more
# stable and more accurate than inferring a block from how the fetch failed.
#
# How the sinkhole is derived without a canary: a regulator points every blocked
# name at ONE address. So an IP that an in-country resolver returns for many
# unrelated domains, while a global resolver returns something different for
# each, can only be a sinkhole. Shared hosting cannot trigger it, because that
# IP shows up in the global answer too.
#
# Run by a.sh before every scan. Never fatal: if discovery fails the scan runs
# exactly as it did before, with whatever config.sh already specified.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_config

# ---- Tunables (override in config.sh) ---------------------------------------
: "${DNS_DISCOVERY_ENABLED:=1}"
: "${DNS_NS_LIST_URL:=https://public-dns.info/nameserver}"   # /<iso2>.txt
: "${DNS_TRUTH_RESOLVER:=8.8.8.8}"        # global view, the "unblocked" answer
: "${DNS_CONTROL_DOMAIN:=www.google.com}" # proves a candidate resolver is alive
: "${DNS_SAMPLE_DOMAINS:=8}"              # domains sampled from the work list
: "${DNS_MAX_CANDIDATES:=120}"            # candidates health-checked per run
: "${DNS_PROBE_RESOLVERS:=12}"            # healthy resolvers probed for a block
: "${DNS_KEEP_RESOLVERS:=4}"              # enforcing resolvers kept for the scan
: "${DNS_SINKHOLE_MIN_HITS:=3}"           # distinct domains sharing one bogus IP
: "${DNS_QUERY_TIMEOUT:=3}"
# The health check is where the wall time goes: nearly every candidate on the
# public list is dead, and each one costs a full timeout. A live resolver
# answers in well under a second, so this can be much tighter than the timeout
# used for the real lookups.
: "${DNS_HEALTH_TIMEOUT:=2}"
# Global public resolvers get listed under every country but are not in-country
# ISP resolvers; some of them (Cloudflare Families, Quad9) filter on their own
# policy, which is not the regulator's blocklist.
: "${DNS_EXCLUDE_RESOLVERS:=^(1\.0\.0\.|1\.1\.1\.|8\.8\.|8\.26\.|9\.9\.9|149\.112\.|208\.67\.2|94\.140\.1|76\.76\.2|185\.228\.16)}"
: "${DNS_SINKHOLE_VERIFY:=1}"             # sanity-check what the sinkhole serves
: "${DNS_SINKHOLE_HTTP_TIMEOUT:=8}"
: "${DNS_SINKHOLE_PATTERN:=mcmc|skmm|acma|blocked|block page|\.gov\.}"
: "${DNS_PARALLEL:=4}"

# Android kills a process tree that spawns too many children: the phantom
# process limit is 32 on Android 12+, and Termux does not just lose the extra
# children -- the whole session dies with SIGKILL (signal 9), which takes a.sh
# and the MacroDroid loop with it. Each background job here costs two processes
# (the subshell and its dig), so keep the fan-out small on the probe boxes.
DNS_HOST_OS="$(uname -o 2>/dev/null || true)"
if [[ "${DNS_HOST_OS}" == "Android" || -n "${TERMUX_VERSION:-}" ]]; then
    if (( DNS_PARALLEL > 2 )); then
        DNS_PARALLEL=2
    fi
fi

SESSION_FILE="${WORK_DIR}/resolvers.session"
NS_CACHE="${WORK_DIR}/nameservers.%s.txt"

dlog() { log "DNS-DISCOVERY $*"; }

# Discovery is best-effort. Any failure leaves the previous behaviour intact.
bail() { dlog "$*"; dlog "Result: keeping existing DNS settings from config.sh."; exit 0; }

[[ "${DNS_DISCOVERY_ENABLED}" == "1" ]] || bail "Disabled (DNS_DISCOVERY_ENABLED=0)."

# ---- Country -> ISO 3166-1 alpha-2 (country_iso lives in lib.sh) ------------
ISO="${DNS_COUNTRY_ISO:-$(country_iso "${FETCH_COUNTRY}")}"
[[ -n "${ISO}" ]] || bail "FETCH_COUNTRY='${FETCH_COUNTRY:-unset}' has no ISO mapping (set DNS_COUNTRY_ISO)."

# ---- One A-query at one resolver, whichever DNS client this box has ----------
DNS_CLIENT=""
if   command -v dig      >/dev/null 2>&1; then DNS_CLIENT="dig"
elif command -v host     >/dev/null 2>&1; then DNS_CLIENT="host"
elif command -v nslookup >/dev/null 2>&1; then DNS_CLIENT="nslookup"
fi
[[ -n "${DNS_CLIENT}" ]] || bail "No dig/host/nslookup on this box."

dns_a() {                      # dns_a <resolver> <host> -> IPv4s, one per line
    local res="$1" h="$2"
    case "${DNS_CLIENT}" in
        dig)
            dig +short +time="${DNS_QUERY_TIMEOUT}" +tries=1 "@${res}" "${h}" 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
            ;;
        host)
            host -W "${DNS_QUERY_TIMEOUT}" -t A "${h}" "${res}" 2>/dev/null \
                | sed -n 's/.*has address \([0-9.]*\).*/\1/p' || true
            ;;
        nslookup)
            nslookup -type=A -timeout="${DNS_QUERY_TIMEOUT}" "${h}" "${res}" 2>/dev/null \
                | sed -n 's/^Address: *\([0-9.]*\)$/\1/p' || true
            ;;
    esac
}

# ---- Sample domains: whatever this instance is actually checking -------------
sample_hosts() {
    local src="" line mid url h n=0
    if [[ -s "${DOMAINS_FILE}" ]]; then
        src="${DOMAINS_FILE}"
    else
        src="$(ls -t "${ARCHIVE_DIR}"/domains-*.txt 2>/dev/null | head -1 || true)"
    fi
    [[ -n "${src}" && -s "${src}" ]] || return 0
    while IFS='|' read -r mid url; do
        [[ -n "${url}" ]] || { url="${mid}"; }
        h="${url#https://}"; h="${h#http://}"; h="${h%%/*}"
        [[ -n "${h}" ]] || continue
        case "${h}" in *.*) ;; *) continue ;; esac
        echo "${h}"
        n=$(( n + 1 ))
        (( n >= DNS_SAMPLE_DOMAINS )) && break
    done < "${src}"
}

HOSTS=()
while IFS= read -r _h; do
    [[ -n "${_h}" ]] && HOSTS+=("${_h}")
done < <(sample_hosts)
(( ${#HOSTS[@]} > 0 )) || bail "No domain list to sample yet (run fetch-domains.sh first)."

# ---- Truth: what the world outside the country sees --------------------------
TRUTH_DIR="$(mktemp -d)"
trap 'rm -rf "${TRUTH_DIR}"' EXIT
:> "${TRUTH_DIR}/all.truth"
truth_hosts=()
for h in ${HOSTS[@]+"${HOSTS[@]}"}; do
    dns_a "${DNS_TRUTH_RESOLVER}" "${h}" | sort -u > "${TRUTH_DIR}/${h}.truth"
    if [[ -s "${TRUTH_DIR}/${h}.truth" ]]; then
        truth_hosts+=("${h}")
        cat "${TRUTH_DIR}/${h}.truth" >> "${TRUTH_DIR}/all.truth"
    fi
done
sort -u -o "${TRUTH_DIR}/all.truth" "${TRUTH_DIR}/all.truth"
(( ${#truth_hosts[@]} >= DNS_SINKHOLE_MIN_HITS )) \
    || bail "Only ${#truth_hosts[@]} sample domains resolve globally; need ${DNS_SINKHOLE_MIN_HITS}."

dlog "Country=${FETCH_COUNTRY} iso=${ISO} sampling ${#truth_hosts[@]} domains (truth via ${DNS_TRUTH_RESOLVER})."

# ---- Does one resolver enforce a blocklist? ----------------------------------
# Prints the sinkhole IP if the same not-in-truth address answers for at least
# DNS_SINKHOLE_MIN_HITS distinct domains. Silent otherwise.
# Classify a divergent address: is it a regulator sinkhole, or just a different
# edge of the real site?
#
#   confirmed - it serves (or redirects to) a regulator notice. One domain is
#               enough, because the page itself is the evidence. Australia needs
#               this: ACMA, TEQSA and the Federal Court piracy blocks each use a
#               DIFFERENT address, so no single IP ever repeats across a batch.
#   silent    - nothing answers, or the address is non-routable. Plausible, but
#               unprovable on its own, so it must repeat across
#               DNS_SINKHOLE_MIN_HITS unrelated domains. Malaysia is this case:
#               175.139.142.25 simply blackholes.
#   site      - something answers and it does not read like a notice. A CDN edge
#               that merely differs in-country lands here and is rejected.
sinkhole_class() {
    local ip="$1"
    # Separate statement on purpose: bash expands every word of a `local` before
    # the new variable exists, so "local ip=$1 marker=...${ip}" would build the
    # marker from the CALLER's ip and every candidate would share one file.
    local marker="${TRUTH_DIR}/class.${ip}"
    if [[ -f "${marker}" ]]; then
        cat "${marker}"
        return 0
    fi

    # Never fetch a non-routable answer: curl would just hit this machine.
    case "${ip}" in
        0.0.0.0|127.*|10.*|192.168.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
            echo "silent" > "${marker}"; cat "${marker}"; return 0 ;;
    esac
    if [[ "${DNS_SINKHOLE_VERIFY}" != "1" ]]; then
        echo "silent" > "${marker}"; cat "${marker}"; return 0
    fi

    local page
    if ! page="$(curl -sS -k -m "${DNS_SINKHOLE_HTTP_TIMEOUT}" -D - -o - \
                      "http://${ip}/" 2>/dev/null)" || [[ -z "${page}" ]]; then
        echo "silent" > "${marker}"
    elif printf '%s' "${page}" | grep -qiE "${DNS_SINKHOLE_PATTERN}"; then
        echo "confirmed" > "${marker}"
    else
        echo "site" > "${marker}"
    fi
    cat "${marker}"
}

# Prints EVERY sinkhole this resolver hands out, because one country can run
# several of them at once.
resolver_sinkhole() {
    local res="$1" h ip cand
    local -a bogus=()
    for h in ${truth_hosts[@]+"${truth_hosts[@]}"}; do
        while read -r ip; do
            [[ -n "${ip}" ]] || continue
            grep -qxF "${ip}" "${TRUTH_DIR}/all.truth" && continue   # a real answer
            bogus+=("${ip}")
        done < <(dns_a "${res}" "${h}" | sort -u)
    done
    (( ${#bogus[@]} > 0 )) || return 1

    local tally="${TRUTH_DIR}/tally.${res}"
    printf '%s\n' "${bogus[@]}" | sort | uniq -c | sort -rn > "${tally}"

    local found=1 cnt cand class
    while read -r cnt cand; do
        [[ -n "${cand}" ]] || continue
        class="$(sinkhole_class "${cand}")"
        case "${class}" in
            confirmed) ;;                                    # the notice proves it
            silent)    (( cnt >= DNS_SINKHOLE_MIN_HITS )) || continue ;;
            *)         continue ;;
        esac
        echo "${cand}"
        found=0
    done < "${tally}"
    return "${found}"
}

# ---- Fast path: are last run's resolvers still enforcing? --------------------
PREV_RESOLVERS=""
if [[ -f "${SESSION_FILE}" ]]; then
    # shellcheck disable=SC1090
    PREV_RESOLVERS="$(. "${SESSION_FILE}" 2>/dev/null && printf '%s' "${DNS_SESSION_RESOLVERS:-}")"
fi

KEPT=""; KEPT_N=0; SINKHOLES=""

# Merge a newline-separated sinkhole list into SINKHOLES, keeping it unique.
add_sinkholes() {
    local ip
    while read -r ip; do
        [[ -n "${ip}" ]] || continue
        case " ${SINKHOLES} " in
            *" ${ip} "*) ;;
            *) SINKHOLES="${SINKHOLES}${SINKHOLES:+ }${ip}" ;;
        esac
    done <<< "$1"
}
if [[ -n "${PREV_RESOLVERS}" ]]; then
    for res in ${PREV_RESOLVERS}; do
        if sink="$(resolver_sinkhole "${res}")" && [[ -n "${sink}" ]]; then
            KEPT="${KEPT}${KEPT:+ }${res}"; KEPT_N=$(( KEPT_N + 1 ))
            add_sinkholes "${sink}"
        fi
        (( KEPT_N >= DNS_KEEP_RESOLVERS )) && break
    done
    (( KEPT_N > 0 )) && dlog "Revalidated ${KEPT_N} resolver(s) from the previous session."
fi

# ---- Full discovery ----------------------------------------------------------
if (( KEPT_N == 0 )); then
    # shellcheck disable=SC2059
    ns_file="$(printf "${NS_CACHE}" "${ISO}")"
    if curl -fsS --max-time 30 "${DNS_NS_LIST_URL}/${ISO}.txt" -o "${ns_file}.tmp" 2>/dev/null; then
        mv "${ns_file}.tmp" "${ns_file}"
        dlog "Fetched $(grep -c . "${ns_file}" 2>/dev/null || echo 0) candidate ${ISO} resolvers."
    else
        rm -f "${ns_file}.tmp"
        [[ -s "${ns_file}" ]] || bail "Could not fetch ${DNS_NS_LIST_URL}/${ISO}.txt and no cached list."
        dlog "Using cached resolver list (download failed)."
    fi

    CANDIDATES=()
    while IFS= read -r _r; do
        [[ -n "${_r}" ]] && CANDIDATES+=("${_r}")
    done < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${ns_file}" \
             | grep -vE "${DNS_EXCLUDE_RESOLVERS}" \
             | head -n "${DNS_MAX_CANDIDATES}")
    (( ${#CANDIDATES[@]} > 0 )) || bail "Resolver list for ${ISO} is empty."

    # Health check, in parallel: a candidate must answer for the control domain.
    HEALTH_DIR="$(mktemp -d)"
    running=0
    for res in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
        {
            out="$(DNS_QUERY_TIMEOUT="${DNS_HEALTH_TIMEOUT}" dns_a "${res}" "${DNS_CONTROL_DOMAIN}")"
            [[ -n "${out}" ]] && echo "${res}" > "${HEALTH_DIR}/${res}"
        } &
        running=$(( running + 1 ))
        if (( running >= DNS_PARALLEL )); then
            wait
            running=0
            # Stop as soon as there are enough live resolvers to probe. Without
            # this the loop walks all DNS_MAX_CANDIDATES every time, which is
            # pure cost once the quota is met.
            found="$(ls -1 "${HEALTH_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
            (( found >= DNS_PROBE_RESOLVERS )) && break
        fi
    done
    wait
    HEALTHY=()
    while IFS= read -r _r; do
        [[ -n "${_r}" ]] && HEALTHY+=("${_r}")
    done < <(cat "${HEALTH_DIR}"/* 2>/dev/null | head -n "${DNS_PROBE_RESOLVERS}")
    rm -rf "${HEALTH_DIR}"
    dlog "${#HEALTHY[@]} of ${#CANDIDATES[@]} candidates answered; probing them for a blocklist."

    for res in ${HEALTHY[@]+"${HEALTHY[@]}"}; do
        if sink="$(resolver_sinkhole "${res}")" && [[ -n "${sink}" ]]; then
            KEPT="${KEPT}${KEPT:+ }${res}"; KEPT_N=$(( KEPT_N + 1 ))
            add_sinkholes "${sink}"
            dlog "Enforcing resolver ${res} -> sinkhole $(printf '%s' "${sink}" | tr '\n' ' ')"
        fi
        (( KEPT_N >= DNS_KEEP_RESOLVERS )) && break
    done
fi

(( KEPT_N > 0 )) || bail "No ${ISO} resolver on the public list is enforcing a blocklist right now."

# ---- Publish the session -----------------------------------------------------
{
    echo "# written by discover-resolvers.sh $(date '+%Y-%m-%d %H:%M:%S')"
    echo "DNS_SESSION_COUNTRY='${FETCH_COUNTRY}'"
    echo "DNS_SESSION_ISO='${ISO}'"
    echo "DNS_SESSION_RESOLVERS='${KEPT}'"
    echo "DNS_SESSION_SINKHOLES='${SINKHOLES}'"
    echo "DNS_SESSION_AT='$(date '+%Y-%m-%d %H:%M:%S')'"
} > "${SESSION_FILE}.tmp"
mv "${SESSION_FILE}.tmp" "${SESSION_FILE}"

dlog "Session ready: country=${FETCH_COUNTRY} iso=${ISO} resolvers=${KEPT} sinkholes=${SINKHOLES}"
