# Private development VM

Provisions bERP HRMS on a private Ubuntu 24.04 VM, reached over an SSH
tunnel. Nothing is exposed to the internet.

This is **not** the production path. For an internet-facing deployment with
nginx and TLS, see [DEPLOYMENT.md](DEPLOYMENT.md). The two are deliberately
separate scripts, because the difference between them is the difference
between a private bench and a public one.

| | `deploy-dev.sh` | `deploy-production.sh` |
|---|---|---|
| nginx | no | yes |
| TLS / certbot | no | yes |
| Firewall | **SSH only** | SSH + 80 + 443 |
| Public DNS | not required | required before running |
| `developer_mode` | 1 | 0 |
| Access | SSH tunnel | public hostname |

## This is not the VM bERP already runs

> **Verified on the bERP development VM, 2026-09-26.** `berp-linux` holds a
> **Docker Compose** deployment — `/srv/berp/deployments/dev/compose.json`,
> eight running containers — on **released frappe 16.33.1 and ERPNext 16.34.2**,
> with `berp_branding` and `berp_lao` installed and no HR app at all.
>
> This script provisions a **native bench** at that same path, with its own
> MariaDB, Redis and a `berp-dev.service` systemd unit. Pointed at that VM it
> would `bench init` into a live deployment directory and run a service
> competing with the compose stack. It now refuses to start when `BENCH_DIR`
> exists and is not a bench, but the safer answer is not to aim it there.
>
> `berp_hrms` does not belong on that VM either: it is `17.0.0-dev` and
> declares `frappe >=17.0.0-dev,<18.0.0`, which 16.33.1 does not satisfy.
> `bench validate-dependencies` fails on it, and `bench get-app` only warns —
> so it may install and then misbehave, which is worse than a refusal. Testing
> `berp_hrms` there needs a `version-16` line of this repository cut from
> upstream `version-16`; see
> [bERP `scripts/apps/README.md`](https://github.com/bstBizEra/bERP/blob/dev/scripts/apps/README.md#berp_hrms).

## Layout

| | Default |
|---|---|
| Service user | `berp` (home `/srv/berp`) |
| Bench | `/srv/berp/deployments/dev` (native bench — **not** the compose path above) |
| Secrets | `/srv/berp/secrets/dev` |
| Site | `dev.berp.bizera.la` |
| Endpoint | `http://127.0.0.1:8080` (inside the VM) |
| Service | `berp-dev.service` |

Every value is overridable by environment variable — `BERP_USER`,
`BERP_HOME`, `BENCH_DIR`, `SECRETS_DIR`, `SITE_NAME`, `APP_PORT`,
`SSH_PORT`, `SERVICE_NAME`.

## The app stack

| App | Source | Branch | Override |
|---|---|---|---|
| `frappe` | `frappe/frappe` | `develop` | `FRAPPE_BRANCH` |
| `erpnext` | **`bstBizEra/bERP`** | `dev_branding_lao_hrms_crm` | `BERP_REPO` / `BERP_BRANCH` |
| `berp_hrms` | `bstBizEra/bERP-HRMS` | `main` | `HRMS_REPO` / `HRMS_BRANCH` |
| `crm` | `bstBizEra/bERP-CRM` | `main` | `CRM_REPO` / `CRM_BRANCH` |
| `berp_branding` | subdirectory of `bERP` | same as `erpnext` | `BERP_SUBAPPS` |
| `berp_lao` | subdirectory of `bERP` | same as `erpnext` | `BERP_SUBAPPS` |

**`bERP` is ERPNext.** Its `pyproject.toml` declares `name = "erpnext"`, so it
occupies the bench's `erpnext` app slot. Installing upstream `frappe/erpnext`
instead produces a bench without the bERP base — and the two cannot coexist,
because they are the same app. This is why `deploy-dev.sh` calls
`setup-bench.sh` with `BENCH_ONLY=1` and installs the apps itself:
`setup-bench.sh` would otherwise fetch upstream ERPNext.

`berp_branding` and `berp_lao` are subdirectories of the bERP repository, not
repositories of their own, and `bench get-app` cannot clone a subdirectory.
They are copied into `apps/` with `rsync` and then `pip install -e`'d — the
same approach `scripts/deploy/berp_deploy.sh` uses in the bERP repo. Install
order puts `erpnext` first, since both declare it in `required_apps`.

### Relationship to `berp_deploy.sh`

The bERP repository has its own delivery pipeline for the two custom apps. It
targets an *existing* bench and defaults to `BENCH=/home/frappe/frappe-bench`,
so point it at this one explicitly:

```bash
BENCH=/srv/berp/deployments/dev ./scripts/deploy/berp_deploy.sh \
  --site dev.berp.bizera.la --source <release-tree> --apps berp_branding,berp_lao
```

`deploy-dev.sh` provisions the bench; `berp_deploy.sh` ships subsequent
changes to the custom apps onto it, with backup and rollback. They are
complementary, not alternatives.

## Deploy

```bash
git clone https://github.com/bstBizEra/bERP-HRMS.git
cd bERP-HRMS
sudo ./scripts/deploy-dev.sh
```

Take a VM snapshot first. Expect 30–45 minutes: it builds a Python 3.14
bench, clones ERPNext, and compiles assets.

The script is idempotent — each stage is skipped when already satisfied, so
after a failure you fix the cause and re-run rather than starting over.

## Reaching it

From your workstation:

```bash
ssh -N -L 18080:127.0.0.1:8080 <vm>
```

Then open <http://127.0.0.1:18080> and sign in as `Administrator`. The
password is on the VM at `/srv/berp/secrets/dev/administrator_password`.

`serve_default_site` is enabled because the tunnel sends
`Host: 127.0.0.1:18080` rather than the site name. Without it Frappe answers
"site not found" and the tunnel looks broken when it is not.

## What keeps it private

Three things, in order of importance:

1. **The firewall allows SSH only.** The script enables `ufw` with just the
   SSH port open, and then *asserts* that 80, 443, the application port,
   3306 and 6379 are not world-reachable — failing loudly if any of them is.
   The application port may bind `0.0.0.0`, so the firewall, not the bind
   address, is the control that matters.
2. **No nginx and no certificate.** There is no public listener to reach.
3. **A production guard.** The script refuses to run if the bench directory,
   site name, secrets path or hostname contains `prod`. Production is a
   separate server and must never receive a deployment shaped like this one.

The SSH port is allowed *before* `ufw` is enabled, so a deploy cannot lock
you out. Pass `SSH_PORT` if yours is non-standard, and keep a second session
open the first time.

## Setup wizard

First login prompts the wizard. Non-interactively:

```bash
sudo -u berp -H bash -lc "cd /srv/berp/deployments/dev && bench --site dev.berp.bizera.la console" <<'PY'
import frappe
from frappe.desk.page.setup_wizard.setup_wizard import setup_complete

# Resolve by pattern - the stored name is "Lao Peoples Democratic Republic",
# without the apostrophe. A literal "Laos" fails with LinkValidationError.
matches = frappe.get_all("Country", filters={"name": ["like", "%Lao%"]}, pluck="name")

setup_complete({
    "language": "English (United States)",
    "country": matches[0] if matches else "United States",
    "timezone": "Asia/Vientiane",
    "currency": "LAK",
    "full_name": "Administrator",
    "email": "admin@bizera.la",
    "password": "admin",
    "company_name": "bERP Dev",
    "company_abbr": "BERP",
    "chart_of_accounts": "Standard",
    "fy_start_date": "2026-01-01",
    "fy_end_date": "2026-12-31",
})
frappe.db.commit()
print("setup_complete:", frappe.db.get_single_value("System Settings", "setup_complete"))
PY
```

## Operating it

```bash
systemctl status berp-dev
journalctl -u berp-dev -f
sudo systemctl restart berp-dev

sudo -u berp -H bash -lc "cd /srv/berp/deployments/dev && bench --site dev.berp.bizera.la migrate"
sudo -u berp -H bash -lc "cd /srv/berp/deployments/dev && bench build"
```

Deploying a change:

```bash
sudo -u berp -H bash -lc "cd /srv/berp/deployments/dev/apps/berp_hrms && git pull origin main"
sudo -u berp -H bash -lc "cd /srv/berp/deployments/dev && bench --site dev.berp.bizera.la migrate && bench build"
sudo systemctl restart berp-dev
```

`developer_mode` is on, which is correct here and wrong in production — it
exposes internals and permits schema edits through the UI.

## Toolchain requirements

These are inherited from the bench and are hard failures with Ubuntu 24.04
defaults. [LOCAL_SETUP.md](LOCAL_SETUP.md) has the detail; in short:

| Requirement | Symptom if wrong |
|---|---|
| Python **3.14** | `SyntaxError` at `type ConfType = ...` (PEP 695) |
| Node **≥ 24** | `The engine "node" is incompatible with this module` |
| MariaDB `utf8mb4` | site creation aborts on charset validation |
| ERPNext installed | import errors across Payroll and Expense Claims |
| `bench` installed by the interpreter its shebang names | `ModuleNotFoundError: jinja2` while `pip list` shows it present |

## Troubleshooting

**Tunnel connects but the page says "site not found".** `serve_default_site`
or `default_site` is missing from
`/srv/berp/deployments/dev/sites/common_site_config.json`.

**Tunnel refuses to connect.** Check the service is up
(`systemctl status berp-dev`) and that something is listening:
`ss -ltn | grep 8080`.

**Assets missing or stale.** `bench build`, then
`bench --site <site> clear-cache`. If the build is killed, the VM is out of
memory — 4 GB is the practical minimum; add swap.

**`bench start` exits immediately under systemd.** Confirm `ExecStart` points
at the real `bench` (`command -v bench`) and that `/usr/local/node24/bin` is
on the unit's `PATH`.

## Status

The bench provisioning this delegates to (`scripts/setup-bench.sh`) is the
sequence that produced a verified working instance, though that instance ran
upstream ERPNext rather than bERP.

Not yet run end-to-end on a VM: the bERP app assembly above, the systemd unit,
the port configuration and the firewall assertions. Treat the first run as a
test, and snapshot beforehand.
