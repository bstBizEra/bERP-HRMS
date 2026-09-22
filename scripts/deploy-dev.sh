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
log "Provisioning the bench (delegating to setup-bench.sh)"
BENCH_USER="${BERP_USER}" \
BENCH_HOME="$(dirname "${BENCH_DIR}")" \
BENCH_DIR="${BENCH_DIR}" \
SITE_NAME="${SITE_NAME}" \
ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
	"${REPO_ROOT}/scripts/setup-bench.sh"

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
