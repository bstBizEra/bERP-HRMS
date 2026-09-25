# Deploying bERP HRMS to a VM

Target: an internet-facing **Ubuntu 24.04 LTS** VM with a public domain and
HTTPS. For running the app on a workstation, see
[LOCAL_SETUP.md](LOCAL_SETUP.md); for a private development VM reached over
an SSH tunnel, see [DEPLOYMENT_DEV.md](DEPLOYMENT_DEV.md).

The result is the conventional Frappe production topology:

```
        internet
           │  443 (TLS, Let's Encrypt)
           ▼
    ┌─────────────┐
    │    nginx    │  static assets, TLS termination, 80 -> 443
    └──────┬──────┘
           │ proxy
    ┌──────┴──────────────────────────────┐
    │  gunicorn (web)   workers  scheduler │  under supervisor
    └──────┬───────────────────┬───────────┘
           │                   │
      ┌────┴────┐        ┌─────┴─────┐
      │ MariaDB │        │   Redis   │
      └─────────┘        └───────────┘
```

## Sizing

| Resource | Minimum | Comfortable |
|---|---|---|
| vCPU | 2 | 4 |
| RAM | 4 GB | 8 GB |
| Disk | 30 GB | 60 GB+ |

The bench alone is roughly 4.5 GB before any data. Asset builds are the
memory-hungry step; with 2 GB they tend to be OOM-killed.

## Before you start

1. **DNS first.** Create an `A` record for your hostname pointing at the VM's
   public IP, and wait for it to propagate. Let's Encrypt validates over
   HTTP, so a certificate cannot be issued before this resolves. The script
   checks and refuses to continue rather than failing halfway.
2. **Keep SSH reachable.** The script enables `ufw`. It allows your SSH port
   *before* enabling the firewall, but if you use a non-standard port, pass
   `SSH_PORT`.
3. **Decide on credentials.** If you do not supply them, strong ones are
   generated and printed once.

## Deploy

```bash
git clone https://github.com/bstBizEra/bERP-HRMS.git
cd bERP-HRMS

sudo DOMAIN=hr.example.com \
     ADMIN_EMAIL=ops@example.com \
     ./scripts/deploy-production.sh
```

Expect it to take a while — it builds a Python 3.14 bench, clones erpnext,
and compiles assets.

### Options

| Variable | Default | Purpose |
|---|---|---|
| `DOMAIN` | *(required)* | Public hostname; also the site name |
| `ADMIN_EMAIL` | *(required)* | Let's Encrypt expiry notices |
| `ADMIN_PASSWORD` | generated | Site Administrator password |
| `DB_ROOT_PASSWORD` | generated | MariaDB root password |
| `SITE_NAME` | `$DOMAIN` | Override if the site name differs from the host |
| `SSH_PORT` | `22` | Allowed through `ufw` before it is enabled |
| `SKIP_TLS` | `0` | `1` serves plain HTTP and skips the DNS check |
| `SKIP_FIREWALL` | `0` | `1` leaves `ufw` alone |
| `BERP_BRANCH` | *(required)* | Branch of `bstBizEra/bERP` to deploy |
| `BERP_REPO` | `bstBizEra/bERP` | The bERP platform repository |
| `HRMS_REPO` / `HRMS_BRANCH` | `bstBizEra/bERP-HRMS` / `main` | |
| `CRM_REPO` / `CRM_BRANCH` | `bstBizEra/bERP-CRM` / `main` | |
| `BERP_SUBAPPS` | `berp_branding berp_lao` | Apps living inside the bERP repo |

**`BERP_BRANCH` is required here and has no default.** The shared installer
defaults it to a *development* branch, and silently shipping that to
production is the mistake worth failing on:

```bash
sudo DOMAIN=hr.example.com ADMIN_EMAIL=ops@example.com \
     BERP_BRANCH=main ./scripts/deploy-production.sh
```

**bERP is ERPNext.** `bstBizEra/bERP`'s `pyproject.toml` declares
`name = "erpnext"`, so it occupies the bench's `erpnext` app slot. Upstream
`frappe/erpnext` is never installed — the two are the same app and cannot
coexist. See [DEPLOYMENT_DEV.md](DEPLOYMENT_DEV.md#the-app-stack) for the full
stack.

The script refuses to run with a well-known or short password on an
internet-facing host. That guard is deliberate — do not work around it.

## What it does

1. Provisions the bench via `scripts/setup-bench.sh` with `BENCH_ONLY=1`
   (Python 3.14, Node 24, MariaDB, Redis), then assembles the bERP app stack
   and creates the site via `scripts/install-berp-apps.sh` — the same shared
   installer `deploy-dev.sh` uses, so the two benches cannot drift.
2. Installs nginx and supervisor, and generates their configuration with
   `bench setup nginx` / `bench setup supervisor`.
3. Removes nginx's default site, which would otherwise shadow ours on :80, and
   blocks `berp_hrms.utils.get_country` — an unauthenticated endpoint that makes a
   third-party geo-IP call per unseen client IP and caches it forever. Nothing
   shipped calls the HTTP route; its real use is as a Jinja method, which is
   unaffected. The change is validated with `nginx -t` and rolled back if it
   fails to parse.
4. Sets `developer_mode 0`, sets `host_name` to your HTTPS URL, enables the
   scheduler, and installs Frappe's backup cron entries — then **asserts** the
   result. It re-reads the config frappe will actually see (site config layered
   over common) and stops the deploy if `developer_mode` is on or an
   `ip-api-key` is set. Setting a value is not the same as holding it.
5. Opens 80, 443 and your SSH port in `ufw`, then enables it.
6. Obtains a certificate with `certbot --nginx --redirect` and leaves the
   renewal timer in place.
7. Verifies `frappe.ping` and `/login` over the public URL, and writes
   credentials to `/root/berp-hrms-credentials.txt` (mode 600).

Move those credentials into your password manager and delete the file.

## First login

The site has not been through the setup wizard; it prompts on first login.
To complete it non-interactively instead:

```bash
cd /home/frappe/frappe-bench
sudo -u frappe bench --site hr.example.com console <<'PY'
import frappe
from frappe.desk.page.setup_wizard.setup_wizard import setup_complete

matches = frappe.get_all("Country", filters={"name": ["like", "%Lao%"]}, pluck="name")

setup_complete({
    "language": "English (United States)",
    "country": matches[0] if matches else "United States",
    "timezone": "Asia/Vientiane",
    "currency": "LAK",
    "full_name": "Administrator",
    "email": "admin@example.com",
    "password": "<the Administrator password>",
    "company_name": "Your Company",
    "company_abbr": "YC",
    "chart_of_accounts": "Standard",
    "fy_start_date": "2026-01-01",
    "fy_end_date": "2026-12-31",
})
frappe.db.commit()
PY
```

Country names vary between datasets — Laos is stored as
`Lao Peoples Democratic Republic`, without the apostrophe. Passing a name
that is not in the `Country` table fails with `LinkValidationError`.

## Operating it

```bash
supervisorctl status              # process health
supervisorctl restart all         # after config changes
journalctl -u nginx -f            # nginx logs
tail -f /home/frappe/frappe-bench/logs/*.log
```

### Backups

`bench setup-backups` installs a scheduled backup. Verify it, and copy the
dumps off the VM — a backup on the same disk as the database is not a backup.

```bash
sudo -u frappe bench --site hr.example.com backup --with-files
ls -la /home/frappe/frappe-bench/sites/hr.example.com/private/backups/
```

Restore:

```bash
sudo -u frappe bench --site hr.example.com restore /path/to/database.sql.gz \
  --with-public-files /path/to/files.tar \
  --with-private-files /path/to/private-files.tar
```

### Deploying a change

```bash
cd /home/frappe/frappe-bench/apps/berp_hrms
sudo -u frappe git pull origin main

cd /home/frappe/frappe-bench
sudo -u frappe bench --site hr.example.com migrate
sudo -u frappe bench build
sudo supervisorctl restart all
```

Take a backup before `migrate`. Schema migrations are not reversible.

### Syncing upstream Frappe HR

This repository keeps full upstream history, so the merge base is still real:

```bash
git fetch upstream develop     # upstream = https://github.com/frappe/hrms.git
git merge upstream/develop
```

Since the app was renamed to `berp_hrms`, expect that merge to conflict across
the tree rather than apply cleanly — upstream still calls the package `hrms`,
and every file that names it differs. The practical shape of a sync is now:
take the merge, resolve by re-applying the rename to the incoming side
(`git checkout --theirs`, then the same mechanical substitution), and review.
[RENAME_TO_BERP_HRMS.md](RENAME_TO_BERP_HRMS.md) records the exact substitution
rule so a sync reproduces it rather than inventing a new one.

Do that on a branch, let it go through review, and deploy it like any other
change — never merge upstream directly on the VM.

## Security notes

- The `Administrator` account is the root of the system. Create named user
  accounts with appropriate roles and stop using it for day-to-day work.
- MariaDB binds to `127.0.0.1`. Keep it that way; do not expose 3306.
- `ufw` allows only SSH, 80 and 443. Port 8000 must never be world-reachable
  — nginx is the only thing that should talk to gunicorn.
- Enable two-factor authentication in **System Settings** before real HR data
  goes in. Payroll and employee records are exactly the kind of data that
  makes a breach a legal problem as well as an operational one.
- Keep `developer_mode` at `0`. Besides exposing internals and permitting schema
  edits through the UI, it is the only thing gating
  `berp_hrms.www.berp_hrms.get_context_for_dev`, which returns the whole boot payload to
  an unauthenticated caller. The deploy asserts it, so turning it on later and
  re-running the script will stop the deploy rather than ship it.
- Leave `ip-api-key` unset. `berp_hrms.utils.get_country` is unauthenticated and
  calls a paid geo-IP API once per client IP it has not seen; the key turns an
  abuse vector into a billable one. The deploy asserts this too, and blocks the
  route at nginx.

## Troubleshooting

**Certificate issuance fails.** Confirm DNS resolves to this VM
(`dig +short A hr.example.com`) and that 80 is reachable from the internet.
Let's Encrypt rate-limits failures, so fix the cause before retrying.

**502 from nginx.** gunicorn is not running. Check `supervisorctl status` and
`/home/frappe/frappe-bench/logs/web.error.log`.

**Site not found.** nginx is routing a hostname the site does not answer to.
Confirm `host_name` matches, re-run `bench setup nginx --yes`, and reload.

**Assets missing or stale.** `sudo -u frappe bench build`, then
`bench --site <site> clear-cache`. If the build is killed, the VM is out of
memory — add swap or a larger instance.

**Scheduled jobs not running.** `bench --site <site> doctor`, and confirm the
scheduler is enabled and not paused.
