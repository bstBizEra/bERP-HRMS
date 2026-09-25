# Running bERP HRMS locally

This app is a Frappe application. It does not run on its own — it needs the
Frappe framework, an ERPNext install, MariaDB and Redis. The two supported
ways to get there are below.

> Deploying to a server rather than a workstation? See
> [DEPLOYMENT.md](DEPLOYMENT.md) for a public, TLS-terminated deployment, or
> [DEPLOYMENT_DEV.md](DEPLOYMENT_DEV.md) for a private development VM reached
> over an SSH tunnel.

Everything here was derived from a clean Ubuntu 24.04 provision; the version
pins are load-bearing and the reasons are in [Toolchain requirements](#toolchain-requirements).

## Option A — native bench (verified)

```bash
sudo ./scripts/setup-bench.sh
su - frappe -c "cd /home/frappe/frappe-bench && bench start"
```

Then add `127.0.0.1 berp.localhost` to `/etc/hosts` and open
<http://berp.localhost:8000>. Default login is `Administrator` / `admin`.

The script is idempotent — re-running it skips any stage that is already
done, so it is safe to re-run after a failure.

Tunables (all environment variables):

| Variable | Default | Purpose |
|---|---|---|
| `SITE_NAME` | `berp.localhost` | Site to create |
| `FRAPPE_BRANCH` | `develop` | Frappe framework branch |
| `ERPNEXT_BRANCH` | `develop` | ERPNext branch |
| `PYTHON_VERSION` | `3.14` | Interpreter for the bench venv |
| `NODE_MAJOR` | `24` | Node major version |
| `DB_ROOT_PASSWORD` | `frappe_dev_root` | MariaDB root password |
| `ADMIN_PASSWORD` | `admin` | Site Administrator password |

> The two default passwords are for local development only. Set both to
> something else before running this anywhere another person can reach.

## Option B — Docker

```bash
cd docker
docker compose up
```

The first run builds the toolchain image and provisions the bench inside the
container; expect it to take a while. Afterwards the app is on
<http://localhost:8000>.

Unlike the upstream compose file, this one mounts **this repository** as the
`berp_hrms` app, so you are running your own code rather than a fresh clone of
`frappe/hrms`.

## Toolchain requirements

These are not style preferences. Each one is a hard failure with the versions
Ubuntu 24.04 ships by default:

| Requirement | Why | Symptom if wrong |
|---|---|---|
| **Python 3.14** | `frappe` v17 sets `requires-python = ">=3.14,<3.15"` and uses PEP 695 `type` statements | `SyntaxError: invalid syntax` at `type ConfType = ...` during the editable install |
| **Node ≥ 24** | `frappe`'s `package.json` sets `"engines": { "node": ">=24" }` | `error frappe-framework@: The engine "node" is incompatible with this module` |
| **MariaDB with `utf8mb4`** | Frappe validates server charset before creating a site | Site creation aborts on charset validation |
| **ERPNext installed** | `berp_hrms/hooks.py` declares `required_apps = ["frappe/erpnext"]`, and ~108 modules import `erpnext` | Import errors across Payroll, Expense Claims and Salary Slips |
| **Non-root user** | `bench` refuses to initialise as root | `bench init` aborts immediately |

Note that `pyproject.toml` in this repo advertises `requires-python = ">=3.10"`.
That value is inherited from upstream and is **misleading** — it describes this
app in isolation, but the framework it depends on will not build below 3.14.
It is left untouched because nothing reads it — bench resolves the interpreter
from the bench's own env, not from this value.

## Gotchas worth knowing

**bench CLI dependencies.** The `bench` entrypoint is installed with the
shebang `#!/usr/bin/python3`. If you install `frappe-bench` with a `pip` bound
to a *different* interpreter, the package lands in a site-packages that
`bench` never reads, and every command dies with
`ModuleNotFoundError: No module named 'jinja2'` while `pip list` cheerfully
shows jinja2 installed. Install with `/usr/bin/python3 -m pip`.

**App directory naming.** `bench get-app <path>` derives the app name from the
directory basename. Pointing it at a checkout called `bERP-HRMS` registers an
app named `bERP-HRMS`, which then fails to import (the Python package is
`berp_hrms`). Stage the clone in a directory literally named `berp_hrms`.

**TLS behind a proxy.** If your machine routes HTTPS through an intercepting
proxy, `uv` will fail with `invalid peer certificate: UnknownIssuer` because it
uses its own bundled roots. Either install the proxy CA into the system trust
store and set `UV_SYSTEM_CERTS=1`, or point `SSL_CERT_FILE` at the CA bundle.

**Corporate egress policies.** Reverse tunnels (Cloudflare Tunnel, SSH-based
tunnels) generally will not work from behind a policy-enforcing proxy:
Cloudflare's edge needs TCP/UDP 7844, and an SSH handshake on 443 gets answered
by the HTTP middlebox with `400 Bad Request`. Run locally instead.

## Completing the setup wizard non-interactively

A fresh site prompts for the setup wizard on first login. To skip the UI:

```bash
cd /home/frappe/frappe-bench
bench --site berp.localhost console <<'PY'
import frappe
from frappe.desk.page.setup_wizard.setup_wizard import setup_complete

# Resolve the country by pattern - stored names vary between datasets
# (for example "Lao Peoples Democratic Republic", without the apostrophe).
matches = frappe.get_all("Country", filters={"name": ["like", "%Lao%"]}, pluck="name")

setup_complete({
    "language": "English (United States)",
    "country": matches[0] if matches else "United States",
    "timezone": "Asia/Vientiane",
    "currency": "LAK",
    "full_name": "Administrator",
    "email": "admin@berp.local",
    "password": "admin",
    "company_name": "bERP Demo Co",
    "company_abbr": "BERP",
    "chart_of_accounts": "Standard",
    "fy_start_date": "2026-01-01",
    "fy_end_date": "2026-12-31",
})
frappe.db.commit()
PY
```

Adjust country, currency, timezone and fiscal year to your entity. Passing a
country name that is not in the `Country` table fails with
`LinkValidationError: Could not find Country: ...`.

## Useful commands

```bash
cd /home/frappe/frappe-bench

bench start                                   # all processes (web, worker, scheduler)
bench serve --port 8000                       # web only, no asset watcher
bench --site berp.localhost migrate           # apply schema changes
bench --site berp.localhost console           # Python REPL with frappe loaded
bench --site berp.localhost mariadb           # SQL shell
bench --site berp.localhost set-admin-password <pw>
bench build                                   # rebuild JS/CSS bundles
```

## Syncing with upstream Frappe HR

This repository keeps full upstream history, so updates merge normally:

```bash
git remote add upstream https://github.com/frappe/hrms.git   # one-time
git fetch upstream develop
git merge upstream/develop
```
