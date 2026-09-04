# Domain Block Checker

Linux/macOS shell-based, multi-telco domain reachability checker for active
dmnbot merchants. Runs on a probe box (typically tethered through a phone /
SIM per telco), pulls the active merchant domain list from the dmnbot API,
probes each host, and reports blocked/cleared status back to the API.

Probes are **headers-only**: a `HEAD` that follows redirects and reads the final
URL plus status, never the page body. Across ~400 single-page casino fronts that
is ~160 KB per full pass instead of ~320 MB, which matters on a metered SIM and
on paid proxy bandwidth.

It can also probe **through a DataImpulse mobile proxy** instead of the local
network, so a box anywhere can check whether a domain is blocked in another
country (e.g. Australia) — see [Proxy mode](#proxy-mode--checking-another-country-dataimpulse-mobile).

## Components

| File                   | Purpose                                                       |
| ---------------------- | ------------------------------------------------------------- |
| `config.sh.example`    | Template — copy to `config.sh` and edit before first run.     |
| `lib.sh`               | Shared helpers (config loader, HTTP, ping/HTTP probe, state). |
| `fetch-domains.sh`     | Hourly cron — pulls domain list, writes the work file.        |
| `check-domains.sh`     | Frequent cron — processes a batch and rotates telcos.         |

## Backend

This depends on these pieces in dmnbot:

* Migrations:
  * `..._create_merchant_domain_block_status_table.php` →
    `merchant_domain_block_status`, keyed by `(merchant_id, domain, telco)`.
  * `..._create_domain_check_runs_table.php` → `domain_check_runs`, holding
    per-telco stat rows (`is_summary=0`) + a final summary row (`is_summary=1`)
    per `run_id`.
* `App\Http\Controllers\CronController` adds 4 actions, registered in
  `routes/api.php` and gated by the `cron` middleware
  (`App\Http\Middleware\VerifyCronKey`, which checks `env('CRON_API_KEY')`).

  Laravel mounts `routes/api.php` under the `/api` prefix, so the real paths are:

  | Endpoint                                  | Method | Purpose                                       |
  | ----------------------------------------- | ------ | --------------------------------------------- |
  | `/api/cron/domain-list?format=text`       | GET    | Active merchants → `mid|host` per line.       |
  |   `&country=Malaysia`                     |        | Optional: country pool (default Malaysia).    |
  |   `&offset=N&limit=M`                     |        | Optional: slice the pool (see below).         |
  | `/api/cron/domain-block-report`           | POST   | Bulk upsert of blocked / cleared domains.     |
  | `/api/cron/domain-check-stats`            | POST   | Per-telco round stats.                         |
  | `/api/cron/domain-check-summary`          | POST   | Final summary after all telcos done.           |

`domain-list` spans **all companies** but exactly **one country**: it returns
the active domains (`merchant_urls.domain_status = 1`) of active merchants
(`merchant_status = 1`) whose `merchant_urls.country` matches the `country`
query param, defaulting to `config('merchants.default_country')` (Malaysia)
when the param is omitted. A checker probes from inside one country, so it is
only ever handed that country's domains. An unrecognised country is a `422`,
not an empty list — a typo in `FETCH_COUNTRY` fails loudly instead of looking
like an empty pool. The country actually served comes back in the
`X-Domain-Country` response header.

Country is a property of the **domain**, not the merchant. One account can run
a Malaysian front and an Australian one, and each domain is returned only to
the checker for its own country — so the same `merchant_id` can legitimately
appear in two different countries' pools, with a different set of hosts under
each.

Each merchant's URLs are stored as individual rows in `merchant_urls` (dmnbot)
and emitted as one `merchant_id|host` line per URL, with no primary/backup
distinction. Block reporting is **record-only**: it upserts status into
`merchant_domain_block_status` and does **not** change `merchant_urls`.

Set `API_BASE` in `config.sh` to include the `/api` prefix (e.g.
`http://dmnbot.test/api`).

Auth: send the secret as `X-CRON-KEY: <secret>` (or `?key=<secret>`). The
secret must match `CRON_API_KEY` in the Laravel `.env` on the API host.

### Choosing the country pool

Set `FETCH_COUNTRY` in `config.sh` to the country this box probes from
(`Malaysia` or `Australia` — the list lives in `config/merchants.php` on the
API host, and the merchants UI offers the same values per domain). Leaving it
empty lets the API apply its own default, Malaysia.

Each country is an independent pool, numbered from 0. The country filter runs
**before** `offset`/`limit`, so a Malaysian instance at `FETCH_OFFSET=300` and
an Australian one at `FETCH_OFFSET=300` are slicing two unrelated lists — never
carry offsets across countries.

### Running multiple checkers concurrently

`domain-list` returns a stably-ordered (`merchants.id`, then `merchant_urls.id`)
list, so `offset`/`limit` slice it deterministically within one country pool.
To run several checker instances against the same pool without them grabbing
the same domains:

1. Copy this whole directory (or just `config.sh`) once per instance, each
   pointing at its own `WORK_DIR` (so state/lock/domains files don't collide).
2. Give each instance a non-overlapping `FETCH_OFFSET` / `FETCH_LIMIT` in its
   `config.sh` (all sharing the same `FETCH_COUNTRY`), e.g.:
   * Instance A: `FETCH_OFFSET=0   FETCH_LIMIT=300` (domains 1-300)
   * Instance B: `FETCH_OFFSET=300 FETCH_LIMIT=300` (domains 301-600)
   * Instance C: `FETCH_OFFSET=600` (no limit — domain 601 to end of pool)
3. Run each instance's `fetch-domains.sh` / `check-domains.sh` on its own
   cron schedule as usual.

The API also returns the pre-slice pool size via the `X-Total-Domains`
response header, so `fetch-domains.sh` logs it and — if an instance's
`FETCH_OFFSET` has moved past the end of a shrinking pool — skips cleanly
instead of treating "0 domains at my offset" as a fatal error.

## Server installation

```bash
# 1. On the API host: run the migrations and set the secret.
cd /path/to/dmnbot
php artisan migrate
echo 'CRON_API_KEY=put-a-long-random-string-here' >> .env

# 2. On the Linux probe box: install scripts.
sudo mkdir -p /opt/domain-check /var/lib/domain-check /var/log/domain-check
sudo cp tools/domain-check/* /opt/domain-check/
cd /opt/domain-check
sudo cp config.sh.example config.sh
sudo chmod 600 config.sh
sudo chmod +x fetch-domains.sh check-domains.sh
sudo nano config.sh   # set API_BASE, CRON_API_KEY, telco list, etc.
```

### Make ping work as a non-root user (optional)

`ping -c N` typically needs CAP_NET_RAW or to be setuid. Either run cron as
root, or:

```bash
sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"
echo 'net.ipv4.ping_group_range=0 2147483647' | sudo tee /etc/sysctl.d/99-ping.conf
```

### Crontab

```cron
# /etc/cron.d/domain-check  (run as root)
0   *    * * *  root  /opt/domain-check/fetch-domains.sh >> /var/log/domain-check/fetch.log 2>&1
*/5 *    * * *  root  /opt/domain-check/check-domains.sh >> /var/log/domain-check/check.log 2>&1
```

## Behaviour walk-through

1. **Top of every hour**: `fetch-domains.sh` runs.
   * If the previous file is still being processed (`DONE != 1` in the state
     file), it logs a message and exits — the file is **not** overwritten.
   * Otherwise it calls `GET /cron/domain-list?format=text` and writes
     `${WORK_DIR}/domains.active.txt` plus a fresh `.state` file with a new
     `RUN_ID`.

2. **Every 5 minutes**: `check-domains.sh` runs.
   * Acquires a pid-based lock (`domains.active.txt.lock.dir`) so two cron
     ticks can't overlap. Works on macOS without GNU `flock`.
   * Honours the 2-minute telco-switch cooldown (`SWITCH_UNTIL`).
   * If `POINTER == 0` and the current telco hasn't been announced yet, it
     prints `RUNNING DOMAIN CHECK WITH TELCO X` and records `TELCO_STARTED_AT`.
   * Reads `BATCH_SIZE` (default 100) lines from the pointer.
   * For each `merchant_id|host` line, two stages:

     **Stage 1 — ICMP (direct mode only).** `ping -c PING_COUNT` runs to read the
     **resolved IP**, not to judge reachability. If it matches one of
     `MCMC_BLOCK_IPS` (edit at the top of `check-domains.sh`, no `config.sh`
     change needed) the regulator has DNS-redirected the name to a sinkhole →
     blocked (`reason=mcmc_block_ip`). Packet loss is recorded in
     `packet_loss_pct` but is **not** a verdict on its own: CDNs and firewalls
     drop ICMP wholesale, so a loss-based rule marks large numbers of perfectly
     reachable hosts as blocked. `PING_LOSS_BLOCK_THRESHOLD` defaults to `101`
     (off); set it to 100 or less to restore that behaviour.

     **Stage 2 — headers-only HTTPS probe.** A `HEAD` against `https://host/`
     following up to `CURL_MAX_REDIRECTS` hops. The verdict comes from the
     **final URL**: landed on a regulator block page (`MCMC_PATTERNS` /
     `BLOCK_PAGE_URL_PATTERNS`) → blocked; HTTP 451 → blocked; redirected
     anywhere else, or not redirected at all → not blocked. Servers answering
     `HEAD` with `405`/`501` (`HEAD_FALLBACK_CODES`) are retried once as `GET`
     with the body discarded, so a verdict never depends on HEAD support. Page
     bodies are not scanned unless `BLOCK_BODY_PROBE_BYTES` is set — see
     [Block-page patterns](#block-page-patterns).

     * On block: appends a one-line remark to
       `domains.active.txt.remarks` and queues a JSON payload.
   * Flushes blocked entries in batches of `REPORT_BATCH_SIZE` to
     `/cron/domain-block-report`.
   * Updates `POINTER` in the state file.

3. **Telco completes the file** (`POINTER >= TOTAL_LINES`):
   * POSTs `/cron/domain-check-stats` with `domains_total`,
     `blocks_detected`, `duration_seconds`, `started_at`, `ended_at`,
     `host_label`, `source_file`.
   * If more telcos remain:
     * Logs `CHANGING TO NEXT TELCO Y. PLEASE WAIT 2MINS.`
     * Sets `SWITCH_UNTIL = now + SWITCH_COOLDOWN_SECONDS`
       (so the next cron ticks within that window are no-ops; this is the
       window for the operator to swap SIM / switch network manually).
     * Advances `TELCO_INDEX`, resets `POINTER=0`, clears `ANNOUNCED_TELCO`.
   * If that was the last telco:
     * POSTs `/cron/domain-check-summary` with `telco_breakdown` JSON
       and total counters.
     * Logs `DONE CHECK AND SUMMARY STATISTIC SENT`.
     * Moves `domains.active.txt`, `.remarks`, `.state` into
       `${ARCHIVE_DIR}/domains-YYYYmmdd-HHMMSS.txt[.*]` for manual recheck.

## Reason codes and dashboard labels

The checker writes precise codes. dmnbot's
`MerchantDomainBlockStatus::REASON_LABELS` collapses them to the three labels
shown in the dashboard and Telegram alerts; the raw code stays in the row, with
the specifics (matched pattern, curl class, exit IP) in `evidence`. The split is
by strength of evidence, not severity:

| Label                       | Codes                                                                                                             |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `MCMC Blocked`              | `mcmc_block_ip`, `mcmc_redirect`                                                                                    |
| `Blocked`                   | `block_page`, `http_451`, `dns_block`                                                                               |
| `Not Stable/Invalid Domain` | `dns_invalid`, `tls_reset`, `connection_reset`, `unreachable`, `timeout`, `proxy_error`, `http_error`, `ping_loss`   |

`Blocked` means positive proof: the probe landed on a regulator block page, got
a legal 451, or the name resolves from the probe box but not at the exit node.
Everything in the third bucket means "could not load it", not "it is blocked".
An unrecognised code falls back to the third label rather than leaking a raw
slug into the UI, so adding a checker reason never breaks the dashboard.

## Proxy mode — checking another country (DataImpulse mobile)

By default the checker probes from whatever network the box is on (a phone
tethered per telco). Set `PROXY_ENABLED=1` in `config.sh` to send every domain
probe through the **DataImpulse mobile gateway** instead, so you can answer
"is this domain blocked in Australia?" without a SIM in that country.

```bash
PROXY_ENABLED=1
PROXY_HOST="gw.dataimpulse.com"
PROXY_PORT=823                 # 823 = rotate IP per request
PROXY_USER="<mobile-plan-login>"
PROXY_PASS="<mobile-plan-password>"
PROXY_COUNTRY="au"
TELCO_LIST=(TELSTRA OPTUS VODAFONE)
TELCO_PROXY_MAP=(
    "TELSTRA=__asn.1221"
    "OPTUS=__asn.4804"
    "VODAFONE=__asn.133612"
)
```

DataImpulse takes targeting options as `__key.value` suffixes on the plan
username, so the above dials the gateway as
`<login>__cr.au__asn.1221` for the TELSTRA pass. Mobile is a separate plan from
residential — use the mobile plan's own login/password. If your plan's syntax
differs, set `PROXY_USER_SUFFIX` and it is appended verbatim.

### What changes in proxy mode

* **No ICMP.** Ping cannot traverse an HTTP/SOCKS proxy, so stage 1 is skipped
  and `packet_loss_pct` is always `0`. `MCMC_BLOCK_IPS` (sinkhole-IP detection)
  is also inert — a proxied request reports the *gateway's* peer address, never
  the target's resolved IP, so there is no way to see what the exit node
  resolved the name to.
* **The stage 1 equivalent is a resolution failure at the exit node**, which is
  also exactly what a dead domain looks like. To tell them apart the checker
  re-resolves from the probe box's own network: resolves here but not at the
  exit → `dns_block` (a real DNS-level block); resolves nowhere → `dns_invalid`
  (expired or misspelled domain, not a block).
* **The verdict comes from how the HTTPS request fails at the exit node:**

  | Symptom at the exit node                          | Result      | `reason`           |
  | ------------------------------------------------- | ----------- | ------------------ |
  | Final URL is a regulator block page               | blocked     | `mcmc_redirect` / `block_page` |
  | HTTP 451 Unavailable For Legal Reasons            | blocked     | `http_451`         |
  | Resolves from the probe box, but not at the exit  | blocked\*   | `dns_block`        |
  | Resolves nowhere (dead / expired domain)          | blocked\*   | `dns_invalid`      |
  | TLS handshake reset                               | blocked\*   | `tls_reset`        |
  | Connection refused / empty reply                  | blocked\*   | `connection_reset` |
  | Gateway reached target but got nothing (5xx)      | blocked\*   | `unreachable`      |
  | Timeout before any status line                    | blocked\*   | `timeout`          |
  | Gateway itself down / auth rejected / 407         | **unknown** | `proxy_error`      |
  | Any real HTTP status from the target              | ok          | `ok`               |

  \* configurable via `PROXY_UNREACHABLE_RESULT` (`blocked` or `unknown`).
  Gateway-side failures are **never** reported as blocked — a broken proxy must
  not look like a nationwide block.

  **A status line settles it.** If curl received any HTTP status the domain
  resolved, connected and answered, so the result is `ok` even when the transfer
  is cut short afterwards. Without that rule a slow exit node turns a healthy
  redirect chain into `reason=timeout`.
* **Retries.** Each domain gets `PROXY_MAX_RETRIES` extra attempts, drawing a
  fresh exit IP each time in rotating mode, so one bad mobile node does not
  produce a false positive.
* **Pre-flight per batch.** Before probing anything, `check-domains.sh` asks
  `PROXY_IP_CHECK_URL` what the exit node is, logs `ip / country / asn`,
  verifies the country matches `PROXY_COUNTRY` (`PROXY_VERIFY_COUNTRY=1`), and
  loads `PROXY_CONTROL_DOMAIN` through the tunnel. If any of those fail the
  batch is skipped with the pointer untouched — a dead or wrong-country session
  can never mark the whole list as blocked.
* **Telco labels become carriers.** `TELCO_LIST` is still what gets reported to
  the API; `TELCO_PROXY_MAP` is what each label actually dials. Each telco pass
  gets a fresh gateway session (`PROXY_SESSION_ID`, persisted in the state file).
* **Cooldown.** `PROXY_SWITCH_COOLDOWN_SECONDS` (default 5s) replaces
  `SWITCH_COOLDOWN_SECONDS` — no SIM to swap by hand.
* **API traffic is never proxied.** Calls to the dmnbot API always go out over
  the box's own network, since `API_BASE` may be a LAN/`.test` host.

### Block-page patterns

`check-domains.sh` carries three pattern lists at the top of the file, all
matched case-insensitively:

| List                      | Matched against | Reported as     |
| ------------------------- | --------------- | --------------- |
| `MCMC_PATTERNS`           | final URL       | `mcmc_redirect` |
| `BLOCK_PAGE_URL_PATTERNS` | final URL       | `block_page`    |
| `BLOCK_PAGE_PATTERNS`     | response body   | `block_page`    |

Host patterns are matched against the **final URL only, never the page body**. A
genuine block *lands* the probe on the regulator's page, so the URL is the
evidence; the regulator's domain merely appearing somewhere in a page is not.
Matching `acma\.gov\.au` against bodies is what put every `kingzo88.*` domain
into the blacklist — those sites cite the regulator in their own Interactive
Gambling Act disclaimer.

`BLOCK_PAGE_PATTERNS` holds distinctive block-page *wording* and is consulted
only by the inline probe below. Tune the URL list for whichever country you
point `PROXY_COUNTRY` at, and keep every entry specific — a bare word like
`blocked` false-positives on ordinary error pages.

**Inline block pages.** A headers-only probe cannot see an ISP that serves its
notice at the original URL with a 200 instead of redirecting. Set
`BLOCK_BODY_PROBE_BYTES` (default `0` = off) to read at most that many bytes and
match `BLOCK_PAGE_PATTERNS` against them; curl is killed by SIGPIPE once the
quota is reached, so the cap is real bandwidth rather than a truncated read. Off
by default because it spends bandwidth on every clean domain to catch a case
most regulators do not use.

### Verifying the setup

```bash
# What does the gateway look like from here?
curl -x http://gw.dataimpulse.com:823 \
     -U '<login>__cr.au:<password>' \
     'http://ip-api.com/json/?fields=status,countryCode,query,as'
# -> {"status":"success","countryCode":"AU","query":"...","as":"AS1221 Telstra..."}
```

Then run `./check-domains.sh` and confirm the first two log lines read
`Proxy exit node: ... country=AU` and `Proxy control check OK`.

## Tuning notes

* `BATCH_SIZE=100` × `~1000 domains` × `5 telcos` gives roughly 50 cron
  ticks for a full pass, plus 4 cooldown windows. With a 5-minute cron that's
  ~4 hours per full sweep — adjust the cron interval / batch size to fit
  your SLA. The user spec said “2 hours per round”; lower the cron interval
  or raise `BATCH_SIZE` to hit that target.
* Each probe is capped by `CURL_CONNECT_TIMEOUT` + `CURL_TIMEOUT` (direct) or
  `PROXY_CONNECT_TIMEOUT` + `PROXY_CURL_TIMEOUT` (proxy), plus `ping -W` via
  `PING_TIMEOUT`. The proxy budget is deliberately far more generous: a proxied
  request pays for the gateway CONNECT, TLS to the target, and another handshake
  per redirect hop. Too small a budget and healthy sites that redirect come back
  as `reason=timeout`.
* Bandwidth is dominated by whether bodies are downloaded at all. Headers-only
  costs ~400 B per domain; `BLOCK_BODY_PROBE_BYTES` adds up to that many bytes
  for every domain the URL check did not already settle.
* Want to mark a domain back to OK? POST the same payload with
  `"status":"cleared"` to `/cron/domain-block-report`.

## Debugging

```bash
# inspect state mid-run
cat /var/lib/domain-check/domains.active.txt.state

# see remarks accumulated this run
tail -20 /var/lib/domain-check/domains.active.txt.remarks

# manually trigger the check loop once (will respect lock + cooldown)
sudo /opt/domain-check/check-domains.sh

# force a fresh fetch
sudo rm /var/lib/domain-check/domains.active.txt*
sudo /opt/domain-check/fetch-domains.sh
```

## Security

* The shared secret is sent in the `X-CRON-KEY` header. Treat it like a
  password — store `config.sh` mode 600, owned by root.
* The new endpoints **only** trust requests carrying that header (and
  `env('CRON_API_KEY')` must be set, otherwise every call returns
  `CRON_API_KEY_NOT_CONFIGURED`).
