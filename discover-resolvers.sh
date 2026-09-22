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
: "${DNS_MIN_RELIABILITY:=0.90}"          # public-dns.info reliability floor
: "${DNS_EXTRA_RESOLVERS:=}"              # extra in-country resolvers, space separated
: "${DNS_ANSWERED_CACHE:=0}"              # remember which resolvers answered
: "${DNS_SESSION_KEEP_ANSWERED:=0}"       # session carries every answering resolver
: "${DNS_REFUSAL_BLOCK:=0}"               # keep resolvers that REFUSE, not sinkhole
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
ANSWERED_CACHE="${WORK_DIR}/resolvers.answered.%s.txt"

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

# One query, both halves of the answer: "<STATUS> <ip> <ip>...".
# Empty means nothing replied. Only the ANSWER section counts, so a CNAME
# chain's addresses still register.
dns_probe() {                  # dns_probe <resolver> <host>
    local res="$1" h="$2" out st ips
    case "${DNS_CLIENT}" in
        dig)
            out="$(dig +time="${DNS_QUERY_TIMEOUT}" +tries=1 "@${res}" "${h}" A 2>/dev/null)" || true
            st="$(printf '%s' "${out}" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1)"
            [[ -n "${st}" ]] || { echo ""; return 0; }
            ips="$(printf '%s' "${out}" \
                   | awk '/^;; ANSWER SECTION:/{a=1;next} /^$/{a=0} a && $4=="A"{print $5}' \
                   | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tr '\n' ' ')"
            printf '%s %s' "${st}" "${ips}"
            ;;
        host|nslookup)
            out="$(host -W "${DNS_QUERY_TIMEOUT}" -t A "${h}" "${res}" 2>&1)" || true
            case "${out}" in
                *"has address"*)     printf 'NOERROR %s' "$(printf '%s' "${out}" \
                                         | sed -n 's/.*has address \([0-9.]*\).*/\1/p' | tr '\n' ' ')" ;;
                *NXDOMAIN*)          echo "NXDOMAIN" ;;
                *SERVFAIL*)          echo "SERVFAIL" ;;
                *REFUSED*)           echo "REFUSED"  ;;
                *"has no A record"*) echo "NOERROR"  ;;
                *)                   echo ""         ;;
            esac
            ;;
    esac
}

# A resolver that REPLIES but hands back no address for names that resolve
# globally is enforcing too. Cambodia blocks that way instead of sinkholing, so
# resolver_sinkhole() finds no bogus address to tally and would discard the very
# resolvers that enforce.
#
# Tested on the RESPONSE, not the response code: the same resolver answered
# NXDOMAIN for six of eight KH domains in one run and NOERROR-with-no-address
# twenty minutes later, so an rcode match flapped between 6 hits and 1.
# Requires the same DNS_SINKHOLE_MIN_HITS agreement across unrelated domains,
# so one dead name or one lost packet cannot qualify a resolver, and a resolver
# that never replies scores zero rather than everything. truth_hosts only ever
# holds names that DID resolve at DNS_TRUTH_RESOLVER.
resolver_refuses() {
    local res="$1" h probe st ips n=0 served=0
    for h in ${truth_hosts[@]+"${truth_hosts[@]}"}; do
        probe="$(dns_probe "${res}" "${h}")"
        [[ -n "${probe}" ]] || continue
        st="${probe%% *}"
        ips="${probe#"${st}"}"
        ips="${ips// /}"
        if [[ -z "${ips}" ]]; then
            n=$(( n + 1 ))
        else
            served=$(( served + 1 ))
        fi
    done

    # Enforcing means withholding SOME names while still serving others. A
    # resolver that withholds every name is broken, not enforcing -- and the
    # difference matters enormously, because the verdict path trusts a proven
    # enforcer on its own. Observed 2026-09-21: 103.242.58.166 entered a state
    # where it returned no address for anything, qualified here on 8 of 8
    # "refusals", and then marked www.google.com, wikipedia.org and
    # example.com as blocked.
    (( served > 0 )) || return 1
    (( n >= DNS_SINKHOLE_MIN_HITS ))
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
PREV_ISO=""
if [[ -f "${SESSION_FILE}" ]]; then
    # shellcheck disable=SC1090
    PREV_RESOLVERS="$(. "${SESSION_FILE}" 2>/dev/null && printf '%s' "${DNS_SESSION_RESOLVERS:-}")"
    # shellcheck disable=SC1090
    PREV_ISO="$(. "${SESSION_FILE}" 2>/dev/null && printf '%s' "${DNS_SESSION_ISO:-}")"
fi

# The fast path re-tests last run's resolvers instead of discovering fresh
# ones. Those resolvers belong to the country they were found in, and they keep
# enforcing their own regulator's list forever -- an AU resolver still answers
# with the ACMA sinkhole when FETCH_COUNTRY has moved on to Cambodia. It would
# pass the re-test and get written back as THIS country's session. So a session
# from another ISO is discarded and full discovery runs for ${ISO}.
if [[ "${DNS_SESSION_FOLLOWS_FETCH:-1}" == "1" \
   && -n "${PREV_RESOLVERS}" && -n "${PREV_ISO}" && "${PREV_ISO}" != "${ISO}" ]]; then
    dlog "Previous session was discovered for '${PREV_ISO}'; this run is '${ISO}'. Discarding it and discovering ${ISO} resolvers from scratch."
    PREV_RESOLVERS=""
fi

KEPT=""; KEPT_N=0; SINKHOLES=""
ANSWERED_ALL=""        # every resolver that replied this run, enforcing or not

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
        elif [[ "${DNS_REFUSAL_BLOCK}" == "1" ]] && resolver_refuses "${res}"; then
            KEPT="${KEPT}${KEPT:+ }${res}"; KEPT_N=$(( KEPT_N + 1 ))
        fi
        (( KEPT_N >= DNS_KEEP_RESOLVERS )) && break
    done
    ANSWERED_ALL="${PREV_RESOLVERS}"
    (( KEPT_N > 0 )) && dlog "Revalidated ${KEPT_N} resolver(s) from the previous session."
fi

# ---- Full discovery ----------------------------------------------------------
if (( KEPT_N == 0 )); then
    # shellcheck disable=SC2059
    ns_file="$(printf "${NS_CACHE}" "${ISO}")"

    # public-dns.info publishes a CSV beside the plain list, carrying a
    # `reliability` column (0.00-1.00: the share of recent checks the resolver
    # answered). Filtering on it up front spends the DNS_MAX_CANDIDATES health
    # budget on resolvers that actually respond -- the .txt is a flat list that
    # still includes entries last seen years ago, and the health check pays a
    # full timeout for each of those.
    #
    # Fields are counted from the RIGHT: `as_org` is quoted and may contain
    # commas ("SMART AXIATA Co., Ltd."), so the field count varies per row,
    # while the trailing three (reliability, checked_at, created_at) never do.
    # $(NF-2) is therefore reliability on every row; $1 is always the IP.
    csv_tmp="${ns_file}.csv.tmp"
    rel_ok=0
    if curl -fsS --max-time 30 "${DNS_NS_LIST_URL}/${ISO}.csv" -o "${csv_tmp}" 2>/dev/null \
       && awk -F, -v min="${DNS_MIN_RELIABILITY}" \
              'NR>1 && $(NF-2)+0 >= min { print $1 }' "${csv_tmp}" \
              > "${ns_file}.tmp" 2>/dev/null \
       && [[ -s "${ns_file}.tmp" ]]; then
        ns_kept="$(grep -c . "${ns_file}.tmp" 2>/dev/null || echo 0)"
        ns_listed="$(grep -c . "${csv_tmp}" 2>/dev/null || echo 1)"
        mv "${ns_file}.tmp" "${ns_file}"
        rel_ok=1
        dlog "Fetched ${ns_kept} of $(( ns_listed - 1 )) listed ${ISO} resolvers (reliability >= ${DNS_MIN_RELIABILITY})."
    fi
    rm -f "${csv_tmp}" "${ns_file}.tmp"

    # Fallback: the plain list, unfiltered, exactly as before.
    if (( rel_ok == 0 )); then
        if curl -fsS --max-time 30 "${DNS_NS_LIST_URL}/${ISO}.txt" -o "${ns_file}.tmp" 2>/dev/null; then
            mv "${ns_file}.tmp" "${ns_file}"
            dlog "Fetched $(grep -c . "${ns_file}" 2>/dev/null || echo 0) candidate ${ISO} resolvers."
        else
            rm -f "${ns_file}.tmp"
            [[ -s "${ns_file}" ]] || bail "Could not fetch ${DNS_NS_LIST_URL}/${ISO}.txt and no cached list."
            dlog "Using cached resolver list (download failed)."
        fi
    fi

    # Operator-known resolvers go in FIRST and are never squeezed out by the
    # DNS_MAX_CANDIDATES cap. public-dns.info only lists resolvers that are open
    # to the whole internet, and the ones a regulator actually enforces on are
    # often an ISP's own -- Cambodia's enforcing resolver 203.189.130.131
    # (COGETEL AS23673) is not on that list at all, so discovery could only ever
    # pick from non-enforcing candidates and bailed every run.
    #
    # Seeded, not trusted: they still face the same health check and the same
    # enforcement probe as any candidate, so a wrong or dead entry is dropped
    # rather than believed.
    # Space separated, any number of entries. Commas are tolerated because
    # writing them is the obvious mistake and would otherwise collapse the whole
    # value into one bogus candidate that just quietly fails the health check.
    CANDIDATES=()
    for _r in ${DNS_EXTRA_RESOLVERS//,/ }; do
        [[ -n "${_r}" ]] || continue
        if [[ ! "${_r}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            dlog "Ignoring DNS_EXTRA_RESOLVERS entry '${_r}': not an IPv4 address."
            continue
        fi
        case " ${CANDIDATES[*]+${CANDIDATES[*]}} " in
            *" ${_r} "*) continue ;;
        esac
        CANDIDATES+=("${_r}")
    done
    # Resolvers that answered a previous run go next, ahead of the public list.
    # That list is a 2023 snapshot in which only a handful are still alive, so
    # the health check is the expensive part of a cold start -- and a run where
    # the one enforcing resolver happens to miss it ends in a bail with no
    # session at all. Front-loading known-live addresses makes that rare.
    # shellcheck disable=SC2059
    answered_file="$(printf "${ANSWERED_CACHE}" "${ISO}")"
    if [[ "${DNS_ANSWERED_CACHE}" == "1" && -s "${answered_file}" ]]; then
        while IFS= read -r _r; do
            [[ -n "${_r}" ]] || continue
            case " ${CANDIDATES[*]+${CANDIDATES[*]}} " in
                *" ${_r} "*) continue ;;
            esac
            CANDIDATES+=("${_r}")
        done < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${answered_file}")
    fi
    while IFS= read -r _r; do
        [[ -n "${_r}" ]] || continue
        case " ${CANDIDATES[*]+${CANDIDATES[*]}} " in
            *" ${_r} "*) continue ;;
        esac
        CANDIDATES+=("${_r}")
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
    ANSWERED_ALL="${HEALTHY[*]+${HEALTHY[*]}}"
    if [[ "${DNS_ANSWERED_CACHE}" == "1" ]] && (( ${#HEALTHY[@]} > 0 )); then
        dlog "Answered: ${HEALTHY[*]}"
        printf '%s\n' ${HEALTHY[@]+"${HEALTHY[@]}"} > "${answered_file}.tmp" \
            && mv "${answered_file}.tmp" "${answered_file}"
    fi

    for res in ${HEALTHY[@]+"${HEALTHY[@]}"}; do
        if sink="$(resolver_sinkhole "${res}")" && [[ -n "${sink}" ]]; then
            KEPT="${KEPT}${KEPT:+ }${res}"; KEPT_N=$(( KEPT_N + 1 ))
            add_sinkholes "${sink}"
            dlog "Enforcing resolver ${res} -> sinkhole $(printf '%s' "${sink}" | tr '\n' ' ')"
        elif [[ "${DNS_REFUSAL_BLOCK}" == "1" ]] && resolver_refuses "${res}"; then
            KEPT="${KEPT}${KEPT:+ }${res}"; KEPT_N=$(( KEPT_N + 1 ))
            dlog "Enforcing resolver ${res} -> refuses to resolve (no sinkhole address)."
        fi
        (( KEPT_N >= DNS_KEEP_RESOLVERS )) && break
    done
fi

(( KEPT_N > 0 )) || bail "No ${ISO} resolver on the public list is enforcing a blocklist right now."

# ---- Publish the session -----------------------------------------------------
# DNS_SESSION_ENFORCING is always the proven subset -- the resolvers that were
# observed handing out a sinkhole or withholding an address. DNS_SESSION_
# RESOLVERS is what the scan actually queries, and with
# DNS_SESSION_KEEP_ANSWERED=1 it widens to every resolver that replied.
#
# Those are deliberately separate. Cambodian ISPs do not enforce the same list
# -- COGETEL withholds addresses that SEATEL resolves normally -- so querying
# more of them finds more blocks, but they must NOT count toward the quorum:
# requiring 2 of 3 to agree when only one enforces reports a blocked domain as
# clean. lib.sh sizes the quorum from DNS_SESSION_ENFORCING for that reason.
SESSION_RESOLVERS="${KEPT}"
if [[ "${DNS_SESSION_KEEP_ANSWERED}" == "1" ]]; then
    for _r in ${ANSWERED_ALL}; do
        case " ${SESSION_RESOLVERS} " in
            *" ${_r} "*) ;;
            *) SESSION_RESOLVERS="${SESSION_RESOLVERS}${SESSION_RESOLVERS:+ }${_r}" ;;
        esac
    done
fi

{
    echo "# written by discover-resolvers.sh $(date '+%Y-%m-%d %H:%M:%S')"
    echo "DNS_SESSION_COUNTRY='${FETCH_COUNTRY}'"
    echo "DNS_SESSION_ISO='${ISO}'"
    echo "DNS_SESSION_RESOLVERS='${SESSION_RESOLVERS}'"
    echo "DNS_SESSION_ENFORCING='${KEPT}'"
    echo "DNS_SESSION_SINKHOLES='${SINKHOLES}'"
    echo "DNS_SESSION_AT='$(date '+%Y-%m-%d %H:%M:%S')'"
} > "${SESSION_FILE}.tmp"
mv "${SESSION_FILE}.tmp" "${SESSION_FILE}"

dlog "Session ready: country=${FETCH_COUNTRY} iso=${ISO} resolvers=${SESSION_RESOLVERS} sinkholes=${SINKHOLES}"
dlog "Enforcing subset (sizes the quorum): ${KEPT}"
