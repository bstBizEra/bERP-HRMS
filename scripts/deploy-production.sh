#!/usr/bin/env bash
#
# Deploy bERP HRMS to an internet-facing Ubuntu 24.04 VM.
#
# Layers a production setup on top of scripts/setup-bench.sh:
#   gunicorn under supervisor, nginx in front, TLS from Let's Encrypt,
#   a scheduler, and a firewall.
#
# Run it on the VM, as root:
#
#   sudo DOMAIN=hr.example.com ADMIN_EMAIL=ops@example.com \
#        ./scripts/deploy-production.sh
#
# Before running, point the domain's DNS A record at this VM - the
# certificate cannot be issued otherwise. The script checks this and stops
# if it does not hold.
#
set -euo pipefail

DOMAIN="${DOMAIN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
BENCH_USER="${BENCH_USER:-frappe}"
BENCH_DIR="${BENCH_DIR:-/home/${BENCH_USER}/frappe-bench}"
SITE_NAME="${SITE_NAME:-${DOMAIN}}"
SSH_PORT="${SSH_PORT:-22}"
SKIP_TLS="${SKIP_TLS:-0}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warning:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo $0)"
[[ -n "${DOMAIN}" ]] || die "Set DOMAIN, e.g. DOMAIN=hr.example.com $0"
[[ -n "${ADMIN_EMAIL}" || "${SKIP_TLS}" == "1" ]] \
	|| die "Set ADMIN_EMAIL (Let's Encrypt expiry notices), or SKIP_TLS=1"

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
# This host is reachable from the internet, so refuse to inherit the
# development defaults. Generate strong values unless they were supplied.
gen_pw() { python3 -c "import secrets,string; a=string.ascii_letters+string.digits; print(''.join(secrets.choice(a) for _ in range(24)))"; }

ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen_pw)}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(gen_pw)}"

for name in ADMIN_PASSWORD DB_ROOT_PASSWORD; do
	value="${!name}"
	case "${value}" in
		admin|root|password|123|changeme|frappe_dev_root)
			die "${name} is a well-known default. Refusing to use it on an internet-facing host." ;;
	esac
	[[ "${#value}" -ge 12 ]] \
		|| die "${name} is shorter than 12 characters. Refusing to use it on an internet-facing host."
done

# ---------------------------------------------------------------------------
# Preflight: DNS must already resolve here, or certbot will fail
# ---------------------------------------------------------------------------
log "Checking that ${DOMAIN} resolves to this machine"
apt-get update -qq
apt-get install -y -qq dnsutils curl >/dev/null

PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
DOMAIN_IP="$(dig +short A "${DOMAIN}" | tail -1 || true)"

echo "  this host : ${PUBLIC_IP:-<unknown>}"
echo "  ${DOMAIN} : ${DOMAIN_IP:-<unresolved>}"

if [[ "${SKIP_TLS}" != "1" ]]; then
	[[ -n "${DOMAIN_IP}" ]] \
		|| die "${DOMAIN} does not resolve. Create the A record first, or pass SKIP_TLS=1."
	if [[ -n "${PUBLIC_IP}" && "${DOMAIN_IP}" != "${PUBLIC_IP}" ]]; then
		die "${DOMAIN} resolves to ${DOMAIN_IP}, not ${PUBLIC_IP}. Fix DNS (or pass SKIP_TLS=1) and re-run."
	fi
fi

# ---------------------------------------------------------------------------
# Base bench
# ---------------------------------------------------------------------------
log "Provisioning the bench (delegating to setup-bench.sh)"
SITE_NAME="${SITE_NAME}" \
ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
BENCH_USER="${BENCH_USER}" \
	"${REPO_ROOT}/scripts/setup-bench.sh"

# ---------------------------------------------------------------------------
# Production services
# ---------------------------------------------------------------------------
log "Installing nginx and supervisor"
apt-get install -y -qq nginx supervisor

log "Generating supervisor and nginx configuration"
# `bench setup production` writes both configs and enables them. It is
# interactive by default; --yes accepts overwriting existing config.
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench setup supervisor --yes --user '${BENCH_USER}'"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench setup nginx --yes"

ln -sf "${BENCH_DIR}/config/supervisor.conf" /etc/supervisor/conf.d/frappe-bench.conf
ln -sf "${BENCH_DIR}/config/nginx.conf" /etc/nginx/conf.d/frappe-bench.conf
# The default site would otherwise shadow ours on port 80.
rm -f /etc/nginx/sites-enabled/default

log "Hardening the site for production"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' set-config developer_mode 0"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' set-config host_name 'https://${DOMAIN}'"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' enable-scheduler"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' clear-cache"
# Frappe's own maintenance/backup cron entries.
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench setup-backups" || warn "bench setup-backups failed; configure backups manually"

nginx -t
systemctl enable --now nginx supervisor
supervisorctl reread
supervisorctl update

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
if [[ "${SKIP_FIREWALL}" != "1" ]]; then
	log "Configuring ufw (allowing SSH on ${SSH_PORT} before enabling)"
	apt-get install -y -qq ufw
	# Order matters - enabling ufw before allowing SSH locks you out.
	ufw allow "${SSH_PORT}/tcp"
	ufw allow 80/tcp
	ufw allow 443/tcp
	ufw --force enable
	ufw status verbose
else
	warn "Firewall skipped (SKIP_FIREWALL=1). Port 8000 must not be world-reachable."
fi

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
if [[ "${SKIP_TLS}" == "1" ]]; then
	warn "TLS skipped. The site is served over plain HTTP - credentials and"
	warn "session cookies travel in clear text. Do not leave it this way."
else
	log "Issuing a Let's Encrypt certificate for ${DOMAIN}"
	apt-get install -y -qq certbot python3-certbot-nginx
	certbot --nginx \
		--non-interactive --agree-tos \
		-m "${ADMIN_EMAIL}" \
		-d "${DOMAIN}" \
		--redirect
	# certbot installs a renewal timer; confirm it is active.
	systemctl list-timers 'certbot*' --no-pager || true
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
log "Verifying"
SCHEME="https"; [[ "${SKIP_TLS}" == "1" ]] && SCHEME="http"

PING="$(curl -fsS --max-time 20 "${SCHEME}://${DOMAIN}/api/method/frappe.ping" || true)"
if [[ "${PING}" == *"pong"* ]]; then
	echo "  frappe.ping  : ${PING}"
else
	warn "frappe.ping did not return pong. Check: supervisorctl status; journalctl -u nginx"
fi

LOGIN_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 "${SCHEME}://${DOMAIN}/login" || true)"
echo "  /login       : HTTP ${LOGIN_CODE}"

CREDS="/root/berp-hrms-credentials.txt"
umask 077
cat > "${CREDS}" <<EOF
bERP HRMS deployment - generated $(date -u +%Y-%m-%dT%H:%M:%SZ)

URL                 ${SCHEME}://${DOMAIN}
Site                ${SITE_NAME}
Administrator       ${ADMIN_PASSWORD}
MariaDB root        ${DB_ROOT_PASSWORD}

Store these in your password manager and delete this file.
EOF

log "Done"
cat <<EOF

  URL       ${SCHEME}://${DOMAIN}
  Login     Administrator
  Password  ${ADMIN_PASSWORD}

  Credentials also written to ${CREDS} (mode 600).
  Move them into your password manager and delete that file.

  The site has not been through the setup wizard; it will prompt on first
  login. See docs/DEPLOYMENT.md for the non-interactive form.

  Service management:
    supervisorctl status
    supervisorctl restart all
    journalctl -u nginx -f

EOF
