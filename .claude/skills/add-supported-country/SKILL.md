---
name: add-supported-country
description: Use when adding a new country/market to the domain-block checker — "add support for <country>", "add a new country", "support Cambodia/Thailand/etc", "add telco <X> with ASN <n>", or when wiring new DataImpulse __cr/__asn targeting. Covers both repos (dmnbot API + dmn-checker probe box), the four edit points, and the mandatory ASN verification.
---

# Adding a supported country

A country spans **two repos**. Both must be edited or the country half-exists:
the API rejects it with a `422` (`dmnbot`), or the probe box cannot map it to an
ISO code and `discover-resolvers.sh` bails (`dmn-checker`).

- `~/Herd/dmnbot` — Laravel API that owns the country list and hands out domains.
- `~/Herd/dmn-checker` — bash probe box (Termux/BlueStacks) that does the checking.

## Hard constraints — read before editing

1. **Never change the core checking logic.** `check_domain` / `check_domain_proxy`
   in `lib.sh`, the verdict cascade, and `discover-resolvers.sh`'s discovery
   algorithm are country-agnostic by design. Adding a country is **data only**:
   an ISO mapping, a telco/ASN table, a list entry.
2. **Never reword, reorder or delete an existing `echo`/`log` line** in
   `dmn-checker`. MacroDroid pattern-matches the exact strings to re-trigger
   `a.sh`; changing one stalls the loop silently. Only ADD lines.
   Verify with `git diff` that no pre-existing output string moved.
3. **Keep fan-out in single digits.** The probe boxes are Termux on Android 13,
   which SIGKILLs the whole session past 32 phantom processes. Verification
   loops here run sequentially with `sleep` between probes.
4. **Do not add a new reason label.** The human-facing reason column is exactly
   two values for every country — `Blocked` and `Not Stable/Invalid Domain`
   (see step 4). Regulator-specific detail lives in the raw code, not the label.

## The four edit points

### 1. `dmnbot` — `config/merchants.php`
Append the country name to `'countries'`. Verbatim string; it is stored in
`merchant_urls.country` and matched against `?country=` on `/api/cron/domain-list`.
Leave `'default_country'` alone unless the user asks.

```php
'countries' => [
    'Malaysia',
    'Australia',
    'Cambodia',      // <- new
],
```
Nothing else in `dmnbot` needs touching: the merchants UI, the API validation
(`Rule::in(config('merchants.countries'))`), the cron country check and the
telco filters all read from this config or from distinct DB values.

### 2. `dmn-checker` — `lib.sh`, `country_iso()`
Add one `case` arm mapping the country name (and its bare ISO) to ISO 3166-1
alpha-2. This feeds both the DataImpulse `__cr.` target and the
`public-dns.info/nameserver/<iso>.txt` resolver list.

```bash
cambodia|kh)          echo "kh" ;;
```
This is the **only** `lib.sh` change. Everything downstream — resolver
discovery, sinkhole learning, the DNS quorum — is already per-ISO generic.

### 3. `dmn-checker` — `config.sh` **and** `config.sh.example`
- Extend the "Known values … " comment above `FETCH_COUNTRY` with the new name.
- Add a **commented** `TELCO_LIST` / `TELCO_PROXY_MAP` preset next to the
  existing ones. Do not flip the active `FETCH_COUNTRY`/`TELCO_LIST` unless the
  user asks — each probe box owns its own `config.sh`, and repointing this one
  moves a live box off its market.
- `PROXY_COUNTRY_FOLLOWS_FETCH=1` makes `__cr.` follow `FETCH_COUNTRY`, so the
  preset only needs the ASNs.

```bash
# TELCO_LIST=(CAMGSM VIETTEL AXIATA)
# TELCO_PROXY_MAP=(
#     "CAMGSM=__asn.17976"
#     "VIETTEL=__asn.38623"
#     "AXIATA=__asn.45498"
# )
```
Telco labels are uppercase and are stored verbatim in the API as
`merchant_domain_block_status.telco` — they drive the UI's telco filter, so pick
the name the user will recognise.

### 4. Reason labels — usually **no change**
`dmnbot/app/Models/MerchantDomainBlockStatus.php::REASON_LABELS` maps every raw
checker code to one of two labels. It is regulator-agnostic on purpose:

- `Blocked` — positive proof (`block_page`, `http_451`, `http_403`, `dns_block`,
  `mcmc_block_ip`, `mcmc_redirect`).
- `Not Stable/Invalid Domain` — no proof, the probe just failed
  (`dns_invalid`, `tls_reset`, `connection_reset`, `unreachable`, `timeout`,
  `proxy_error`, `http_error`, `ping_loss`), and the fallback for any
  unclassified code.

A new country needs a new entry here **only** if you also add a new raw reason
code to `lib.sh` — and then map it to one of these two, never to a third label.
`reasonLabelOptions()` and the blacklist filter derive from this map, so they
follow automatically.

## Step 5 (sometimes): the country may not sinkhole at all

MY and AU point a blocked name at a sinkhole ADDRESS, which is what
`resolver_sinkhole()` tallies and what the whole learned-sinkhole design
assumes. Cambodia does not — its resolvers simply hand back **no address** for
a blocked name. Symptom: discovery bails every run with "No <iso> resolver on
the public list is enforcing a blocklist right now", `DNS_SESSION_RESOLVERS`
stays empty, and because that also leaves `PROXY_LOCAL_DNS_CHECK=0` the entire
DNS stage is skipped — so no DNS guard ever runs, however it is configured.

Four config knobs cover this, all defaulting off so MY/AU are untouched:

| Knob | What it does |
| --- | --- |
| `DNS_REFUSAL_BLOCK=1` | count "replied, but gave no address" as a block (`dns_refused`) |
| `DNS_EXTRA_RESOLVERS` | seed in-country resolvers public-dns.info does not list |
| `DNS_SESSION_KEEP_ANSWERED=1` | query every answering resolver, not just proven enforcers |
| `DNS_ANSWERED_CACHE=1` | log and remember which resolvers answered |

Three things that cost real time when working this out:

1. **Do not match on the response CODE.** The same resolver returned NXDOMAIN
   for six of eight domains in one run and NOERROR with an empty answer
   (NODATA) twenty minutes later. Test whether an ADDRESS came back, not which
   rcode did, and never count a timeout — a dead resolver answers nothing for
   everything and would convict the whole batch.
2. **The enforcing resolver may not be on public-dns.info.** That list only
   carries resolvers open to the whole internet; a regulator enforces on an
   ISP's own recursive resolver. Cambodia's `203.189.130.131` (COGETEL
   AS23673) is not listed, so discovery could only ever pick non-enforcing
   candidates. Find one by hand (`nslookup <blocked-domain> <resolver>`) and
   put it in `DNS_EXTRA_RESOLVERS`.
3. **ISPs in one country run different lists.** Widening the session finds more
   blocks, but non-enforcing resolvers must not size the quorum or a real block
   reports clean on a 1-of-3 vote. `lib.sh` sizes it from
   `DNS_SESSION_ENFORCING` and accepts either a proven enforcer or
   `DNS_BLOCK_QUORUM` agreeing resolvers.

Any new raw reason code still has to be mapped in `dmnbot` (step 4) or it
displays as "Not Stable/Invalid Domain".

## Mandatory: verify the ASNs before declaring it done

DataImpulse silently serves a different exit (or an empty body) when the
requested ASN has no node in the **mobile** pool. Fixed-line/backbone ASNs
routinely have none. Probe each ASN at least twice and confirm the `as` field
echoes the ASN you asked for:

Run this under **`bash`**, not zsh. zsh does not word-split an unquoted
variable, so the common `for spec in "kh 17976"; do set -- $spec` idiom silently
sends `__asn.` with an EMPTY value — no ASN filter at all. The gateway then
returns whatever exit is free, which reads exactly like "targeting is ignored"
and will send you chasing a bug that is in your test harness. Keep the literal
`for asn in ...` list below, or run the whole snippet with `bash <<'EOF'`.

```bash
cd ~/Herd/dmn-checker
USER_ID=$(grep -m1 '^PROXY_USER=' config.sh | cut -d'"' -f2)
PASS=$(grep -m1 '^PROXY_PASS=' config.sh | cut -d'"' -f2)
URL="http://ip-api.com/json/?fields=status,countryCode,query,as"
for asn in 17976 38623 45498; do
  echo "== __cr.kh__asn.${asn} =="
  for i in 1 2; do
    curl -sS --max-time 30 -x "http://${USER_ID}__cr.kh__asn.${asn}:${PASS}@gw.dataimpulse.com:823" "$URL"
    echo; sleep 3
  done
done
```

Read the result carefully. Probe each ASN **at least four times** and treat a
single clean pass as inconclusive — a transient empty body shows up on healthy
ASNs too (the AU control returned one in four):

| Observed                          | Meaning                                                      |
| --------------------------------- | ------------------------------------------------------------ |
| `as` matches on every try          | Usable. Add it to `TELCO_PROXY_MAP`.                          |
| Empty body, `rc=0`, repeatedly     | **No exit on that ASN.** `proxy_health_check` fails the control domain and skips that telco's batch — safe, but that telco yields no data. |
| Empty body once, then matches      | Transient. Normal; `PROXY_MAX_ATTEMPTS` covers it.            |
| `as` differs from the request      | Check the harness for the zsh trap above FIRST, then re-run.  |
| `countryCode` differs              | Wrong-country exit; `PROXY_VERIFY_COUNTRY=1` skips the batch. |

Record the measured outcome as a comment beside the preset, so the next person
does not re-litigate it. If an ASN turns out unusable, still add it as the user
specified, **and tell them**, offering a verified carrier in its place.

**This is not hypothetical.** Cambodia was first specified as
`TELECOM=__asn.17926`. AS17926 is Telecom Cambodia — a real Cambodian operator,
correct on paper — but it is *fixed-line*, so the MOBILE plan had no exit on it
and every probe returned an empty body. The working third carrier was AS17976
(CAMGSM / Cellcard). A plausible-looking ASN from a carrier list is not
evidence; only the probe is. Watch for fixed-line, backbone and IXP operators
mixed in among the mobile ones.

## Optional follow-ups

- Switching an existing box's `FETCH_COUNTRY` leaves the previous country's
  `resolvers.session` in `WORK_DIR`. `DNS_SESSION_FOLLOWS_FETCH=1` (default)
  discards it on both sides — `lib.sh` refuses to apply it and
  `discover-resolvers.sh` refuses to re-test it — so you do not have to delete
  it by hand. The file is left in place so switching back reuses it.
- DNS enforcement is discovered per run, but it needs at least
  `DNS_SINKHOLE_MIN_HITS` (3) genuinely blocked domains in the fetched sample.
  A brand-new country with no blocked domains yet will log "no enforcing
  resolver found" — that is expected, not a bug. The HTTP stage still runs.
- `README.md` — the "Choosing the country pool" section lists the valid values.

## Done checklist

- [ ] `config/merchants.php` lists the country; `php -l` clean.
- [ ] `country_iso()` returns the ISO for both the name and the bare code.
- [ ] `config.sh` + `config.sh.example` carry the preset; `bash -n` clean.
- [ ] Every ASN probed ≥2× and the result written down.
- [ ] `git diff` in `dmn-checker` shows **no** changed `echo`/`log` string.
- [ ] Reason labels still resolve to exactly two values.
