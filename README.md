# Domain Block Checker

Linux/macOS shell-based, multi-telco domain reachability checker for active
dmnbot merchants. Runs on a probe box (typically tethered through a phone /
SIM per telco), pulls the active merchant domain list from the dmnbot API, pings
+ HTTP-probes each host, and reports blocked/cleared status back to the API.

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
  | `/api/cron/domain-block-report`           | POST   | Bulk upsert of blocked / cleared domains.     |
  | `/api/cron/domain-check-stats`            | POST   | Per-telco round stats.                         |
  | `/api/cron/domain-check-summary`          | POST   | Final summary after all telcos done.           |

`domain-list` is **global** — it returns active merchants across **all
companies** (`merchant_status = 1`). Each merchant's URLs are stored as
individual rows in `merchant_urls` (dmnbot) and emitted as one
`merchant_id|host` line per URL, with no primary/backup distinction. Block
reporting is **record-only**: it upserts status into
`merchant_domain_block_status` and does **not** change `merchant_urls`.

Set `API_BASE` in `config.sh` to include the `/api` prefix (e.g.
`http://dmnbot.test/api`).

Auth: send the secret as `X-CRON-KEY: <secret>` (or `?key=<secret>`). The
secret must match `CRON_API_KEY` in the Laravel `.env` on the API host.

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
   * For each `merchant_id|host` line:
     * Runs `ping -c PING_COUNT` and parses packet-loss %.
     * If the resolved IP matches one of `MCMC_BLOCK_IPS` (edit these at the
       top of `check-domains.sh`, no `config.sh` change needed) → blocked
       (`reason=mcmc_block_ip`), regardless of packet loss.
     * If loss ≥ `PING_LOSS_BLOCK_THRESHOLD` (100% by default) → blocked
       (`reason=ping_loss`).
     * Otherwise runs `curl -L` against `https://host/` (falls back to
       `http://`), inspects the final URL and the response body for any of
       the configured `MCMC_PATTERNS` (also at the top of `check-domains.sh`).
       A match → blocked (`reason=mcmc_redirect`).
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

## Tuning notes

* `BATCH_SIZE=100` × `~1000 domains` × `5 telcos` gives roughly 50 cron
  ticks for a full pass, plus 4 cooldown windows. With a 5-minute cron that's
  ~4 hours per full sweep — adjust the cron interval / batch size to fit
  your SLA. The user spec said “2 hours per round”; lower the cron interval
  or raise `BATCH_SIZE` to hit that target.
* If a single host is too slow it can stall a batch. `curl --max-time` and
  `ping -W` already cap each probe; tune via `CURL_TIMEOUT` and
  `PING_TIMEOUT` in `config.sh`.
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
