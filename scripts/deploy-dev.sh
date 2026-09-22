#!/usr/bin/env bash
#
# Provision a PRIVATE bERP HRMS development bench on an Ubuntu 24.04 VM.
#
# Unlike scripts/deploy-production.sh this deliberately does NOT expose the
# site: no nginx, no certificate, and the firewall opens SSH only. The bench
# is reached by forwarding its port over SSH from your workstation:
#
#   ssh -N -L 18080:127.0.0.1:8080 <vm>
#   then open http://127.0.0.1:18080
#
# Run it on the VM, as root:
#
#   sudo ./scripts/deploy-dev.sh
#
# Every stage is skipped when already satisfied, so it is safe to re-run
# after a failure.
#
set -euo pipefail

BERP_USER="${BERP_USER:-berp}"
BERP_HOME="${BERP_HOME:-/srv/berp}"
BENCH_DIR="${BENCH_DIR:-${BERP_HOME}/deployments/dev}"
SECRETS_DIR="${SECRETS_DIR:-${BERP_HOME}/secrets/dev}"
SITE_NAME="${SITE_NAME:-dev.berp.bizera.la}"
APP_PORT="${APP_PORT:-8080}"
SSH_PORT="${SSH_PORT:-22}"
SERVICE_NAME="${SERVICE_NAME:-berp-dev}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
SKIP_SERVICE="${SKIP_SERVICE:-0}"

# The bERP platform. bstBizEra/bERP is a fork of ERPNext - its pyproject
# declares `name = "erpnext"` - so it occupies the bench's `erpnext` app slot.
# Installing upstream frappe/erpnext instead would give a bench without the
# bERP base, and the two cannot coexist: they are the same app.
BERP_REPO="${BERP_REPO:-https://github.com/bstBizEra/bERP.git}"
BERP_BRANCH="${BERP_BRANCH:-dev_branding_lao_hrms_crm}"
HRMS_REPO="${HRMS_REPO:-https://github.com/bstBizEra/bERP-HRMS.git}"
HRMS_BRANCH="${HRMS_BRANCH:-main}"
CRM_REPO="${CRM_REPO:-https://github.com/bstBizEra/bERP-CRM.git}"
CRM_BRANCH="${CRM_BRANCH:-main}"

# Apps that live as subdirectories of the bERP repo rather than as their own
# repositories. bench get-app cannot clone a subdirectory, so these are copied
# into apps/ and pip-installed - the same approach scripts/deploy/berp_deploy.sh
# uses in the bERP repo.
BERP_SUBAPPS="${BERP_SUBAPPS:-berp_branding berp_lao}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warning:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo $0)"

# ---------------------------------------------------------------------------
# Refuse to touch production
# ---------------------------------------------------------------------------
# Development and production live on separate servers, and production must
# never receive a deployment shaped like this one (private, unencrypted,
# developer-oriented). Fail loudly rather than rely on the operator noticing.
for value in "${BENCH_DIR}" "${SITE_NAME}" "${SECRETS_DIR}" "$(hostname -f 2>/dev/null || hostname)"; do
	case "${value}" in
		*prod*|*PROD*|*Prod*)
			die "'${value}' looks like production. This script provisions a private development bench and must not be used there." ;;
	esac
done

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
gen_pw() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; }

read_or_create_secret() {
	# Reuses an existing secret so re-runs do not invalidate a working bench.
	local path="$1"
	if [[ -s "${path}" ]]; then
		cat "${path}"
	else
		local value
		value="$(gen_pw)"
		printf '%s' "${value}" > "${path}"
		chmod 600 "${path}"
		printf '%s' "${value}"
	fi
}

log "Preparing ${SECRETS_DIR}"
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"
chmod 700 "$(dirname "${SECRETS_DIR}")" 2>/dev/null || true

DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(read_or_create_secret "${SECRETS_DIR}/mariadb_root_password")}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(read_or_create_secret "${SECRETS_DIR}/administrator_password")}"

# ---------------------------------------------------------------------------
# Service account
# ---------------------------------------------------------------------------
# Created here rather than by setup-bench.sh so the home directory lands under
# ${BERP_HOME} instead of /home. setup-bench.sh skips creation when the user
# already exists.
log "Ensuring ${BERP_USER} exists with home ${BERP_HOME}"
if ! id "${BERP_USER}" >/dev/null 2>&1; then
	useradd --system --create-home --home-dir "${BERP_HOME}" --shell /bin/bash "${BERP_USER}"
fi
mkdir -p "${BERP_HOME}/deployments"
chown -R "${BERP_USER}:${BERP_USER}" "${BERP_HOME}/deployments"
chown "${BERP_USER}:${BERP_USER}" "${BERP_HOME}"

# ---------------------------------------------------------------------------
# Bench
# ---------------------------------------------------------------------------
# setup-bench.sh runs `cd $BENCH_HOME && bench init $(basename $BENCH_DIR)`,
# so BENCH_HOME must be the PARENT of the deployment directory.
# BENCH_ONLY stops setup-bench.sh after `bench init`: it would otherwise
# install upstream frappe/erpnext, which is the wrong platform here.
log "Provisioning the bench (delegating to setup-bench.sh, apps excluded)"
BENCH_ONLY=1 \
BENCH_USER="${BERP_USER}" \
BENCH_HOME="$(dirname "${BENCH_DIR}")" \
BENCH_DIR="${BENCH_DIR}" \
SITE_NAME="${SITE_NAME}" \
ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
	"${REPO_ROOT}/scripts/setup-bench.sh"

# ---------------------------------------------------------------------------
# Apps
# ---------------------------------------------------------------------------
as_berp() { su - "${BERP_USER}" -c "$1"; }

SRC_DIR="${BERP_HOME}/src"
as_berp "mkdir -p '${SRC_DIR}'"

get_git_app() {
	# $1 app name (must match the Python package), $2 repo url, $3 branch
	local app="$1" url="$2" branch="$3" stage="${SRC_DIR}/$1"
	if [[ -d "${BENCH_DIR}/apps/${app}" ]]; then
		echo "apps/${app} already present, skipping"
		return 0
	fi
	# Staged under a directory named for the app: bench get-app takes the app
	# name from the directory basename, so cloning bERP.git directly would
	# register an app called "bERP" that then fails to import.
	as_berp "rm -rf '${stage}' && git clone -q --depth 1 --branch '${branch}' '${url}' '${stage}'"
	as_berp "cd '${BENCH_DIR}' && bench get-app --skip-assets '${stage}'"
	as_berp "cd '${BENCH_DIR}/apps/${app}' && git remote set-url origin '${url}'"
}

log "Installing erpnext from bERP (${BERP_BRANCH})"
get_git_app erpnext "${BERP_REPO}" "${BERP_BRANCH}"

log "Installing hrms (${HRMS_BRANCH})"
get_git_app hrms "${HRMS_REPO}" "${HRMS_BRANCH}"

log "Installing crm (${CRM_BRANCH})"
get_git_app crm "${CRM_REPO}" "${CRM_BRANCH}"

log "Installing bERP sub-apps: ${BERP_SUBAPPS}"
# These live inside the bERP repo, so reuse the erpnext checkout rather than
# cloning it again.
BERP_SRC="${BENCH_DIR}/apps/erpnext"
command -v rsync >/dev/null || apt-get install -y -qq rsync
for app in ${BERP_SUBAPPS}; do
	[[ -f "${BERP_SRC}/${app}/pyproject.toml" ]] \
		|| die "${BERP_SRC}/${app} is not an app (no pyproject.toml) - is ${BERP_BRANCH} the right branch?"
	[[ -f "${BERP_SRC}/${app}/${app}/hooks.py" ]] \
		|| die "${BERP_SRC}/${app}/${app}/hooks.py missing - wrong tree?"

	as_berp "mkdir -p '${BENCH_DIR}/apps/${app}'"
	as_berp "rsync -a --delete --exclude '.git' --exclude '__pycache__' --exclude 'node_modules' \
		'${BERP_SRC}/${app}/' '${BENCH_DIR}/apps/${app}/'"
	as_berp "'${BENCH_DIR}/env/bin/pip' install --quiet --upgrade -e '${BENCH_DIR}/apps/${app}'"
	# bench reads apps.txt to know what exists; get-app would have written it.
	as_berp "grep -qxF '${app}' '${BENCH_DIR}/sites/apps.txt' 2>/dev/null \
		|| echo '${app}' >> '${BENCH_DIR}/sites/apps.txt'"
done

# ---------------------------------------------------------------------------
# Site
# ---------------------------------------------------------------------------
log "Creating site ${SITE_NAME}"
if [[ ! -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]; then
	as_berp "cd '${BENCH_DIR}' && bench new-site '${SITE_NAME}' \
		--db-root-username root \
		--db-root-password '${DB_ROOT_PASSWORD}' \
		--admin-password '${ADMIN_PASSWORD}' \
		--set-default"
fi

# erpnext first: berp_branding and berp_lao both declare it in required_apps.
log "Installing apps onto ${SITE_NAME}"
for app in erpnext hrms crm ${BERP_SUBAPPS}; do
	as_berp "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' list-apps | grep -qw '${app}'" \
		&& { echo "${app} already installed on the site"; continue; }
	as_berp "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' install-app '${app}'"
done

log "Building assets"
as_berp "cd '${BENCH_DIR}' && bench build"

# ---------------------------------------------------------------------------
# Bench configuration
# ---------------------------------------------------------------------------
log "Configuring the bench for port ${APP_PORT}"
common_config="${BENCH_DIR}/sites/common_site_config.json"
[[ -f "${common_config}" ]] || die "Expected ${common_config} after setup-bench.sh"

# serve_default_site matters here: the SSH tunnel sends `Host: 127.0.0.1:18080`
# rather than the site name, so without it Frappe answers "site not found".
python3 - "${common_config}" "${APP_PORT}" "${SITE_NAME}" <<'PY'
import json, sys
path, port, site = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path) as fh:
    cfg = json.load(fh)
cfg["webserver_port"] = port
cfg["serve_default_site"] = True
cfg.setdefault("default_site", site)
cfg["developer_mode"] = 1
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=1)
print(f"webserver_port={port} serve_default_site=True default_site={cfg['default_site']}")
PY
chown "${BERP_USER}:${BERP_USER}" "${common_config}"

su - "${BERP_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' enable-scheduler" \
	|| warn "enable-scheduler failed; enable it manually if background jobs are needed"

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------
if [[ "${SKIP_SERVICE}" != "1" ]]; then
	log "Installing the ${SERVICE_NAME} service"
	bench_bin="$(command -v bench || echo /usr/local/bin/bench)"
	cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=bERP HRMS development bench (${SITE_NAME})
After=network.target mariadb.service redis-server.service

[Service]
Type=simple
User=${BERP_USER}
WorkingDirectory=${BENCH_DIR}
ExecStart=${bench_bin} start
Restart=on-failure
RestartSec=10
Environment=PATH=/usr/local/node24/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now "${SERVICE_NAME}"
else
	warn "Service installation skipped (SKIP_SERVICE=1). Start it with: bench start"
fi

# ---------------------------------------------------------------------------
# Firewall - SSH only
# ---------------------------------------------------------------------------
# This is what keeps the bench private. The application port may bind
# 0.0.0.0, so the firewall, not the bind address, is the control that matters.
if [[ "${SKIP_FIREWALL}" != "1" ]]; then
	log "Restricting the firewall to SSH on ${SSH_PORT}"
	apt-get install -y -qq ufw
	# Allowed before enabling, otherwise this locks the operator out.
	ufw allow "${SSH_PORT}/tcp"
	ufw --force enable

	# Deliberately assert the opposite of the production script: nothing
	# web-facing should be reachable from outside this VM.
	if ufw status | grep -qE '(^|[^0-9])(80|443|'"${APP_PORT}"'|3306|6379)/tcp .*ALLOW'; then
		ufw status verbose
		die "A web or database port is open to the world. This bench must stay private."
	fi
	ufw status verbose
else
	warn "Firewall skipped (SKIP_FIREWALL=1). Ensure port ${APP_PORT} is not reachable from outside the VM."
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
log "Verifying"
ping_out=""
for _ in $(seq 1 30); do
	ping_out="$(curl -fsS --max-time 5 "http://127.0.0.1:${APP_PORT}/api/method/frappe.ping" 2>/dev/null || true)"
	[[ "${ping_out}" == *"pong"* ]] && break
	sleep 5
done

if [[ "${ping_out}" == *"pong"* ]]; then
	echo "  frappe.ping : ${ping_out}"
else
	warn "frappe.ping did not return pong."
	warn "Check: systemctl status ${SERVICE_NAME}; journalctl -u ${SERVICE_NAME} -n 50"
fi

login_code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${APP_PORT}/login" 2>/dev/null || true)"
echo "  /login      : HTTP ${login_code}"

log "Done"
cat <<EOF

  Bench     ${BENCH_DIR}
  Site      ${SITE_NAME}
  Endpoint  http://127.0.0.1:${APP_PORT}   (inside the VM only)
  Service   systemctl status ${SERVICE_NAME}

  Reach it from your workstation with an SSH tunnel:

    ssh -N -L 18080:127.0.0.1:${APP_PORT} <this-vm>

  then open http://127.0.0.1:18080 and sign in as Administrator.

  Password  ${SECRETS_DIR}/administrator_password
  DB root   ${SECRETS_DIR}/mariadb_root_password

  The site has not been through the setup wizard; it prompts on first login.
  See docs/DEPLOYMENT_DEV.md for the non-interactive form.

EOF
