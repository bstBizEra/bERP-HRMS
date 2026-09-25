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
# BENCH_ONLY stops setup-bench.sh after `bench init`: it would otherwise
# install upstream frappe/erpnext, which is the wrong platform. bstBizEra/bERP
# is a fork of ERPNext declaring `name = "erpnext"`, so it occupies that same
# app slot and the two cannot coexist.
log "Provisioning the bench (delegating to setup-bench.sh, apps excluded)"
BENCH_ONLY=1 \
SITE_NAME="${SITE_NAME}" \
ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
BENCH_USER="${BENCH_USER}" \
	"${REPO_ROOT}/scripts/setup-bench.sh"

# ---------------------------------------------------------------------------
# Apps and site
# ---------------------------------------------------------------------------
# Shared with deploy-dev.sh so the two benches cannot drift. A production
# bench differing from the one changes were tested against is precisely the
# failure this shared path exists to prevent.
# The shared installer defaults BERP_BRANCH to a development branch. Silently
# shipping that to production is exactly the mistake worth failing on, so the
# branch must be named here.
[[ -n "${BERP_BRANCH:-}" ]] || die "Set BERP_BRANCH explicitly for production (e.g. BERP_BRANCH=main). The installer's default is a development branch."

log "Assembling the bERP app stack (bERP @ ${BERP_BRANCH})"
BENCH_USER="${BENCH_USER}" \
BENCH_DIR="${BENCH_DIR}" \
SITE_NAME="${SITE_NAME}" \
ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
BERP_REPO="${BERP_REPO:-}" BERP_BRANCH="${BERP_BRANCH:-}" \
HRMS_REPO="${HRMS_REPO:-}" HRMS_BRANCH="${HRMS_BRANCH:-}" \
CRM_REPO="${CRM_REPO:-}" CRM_BRANCH="${CRM_BRANCH:-}" \
BERP_SUBAPPS="${BERP_SUBAPPS:-}" \
	"${REPO_ROOT}/scripts/install-berp-apps.sh"

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

log "Blocking the unauthenticated geo-IP endpoint"
# berp_hrms.utils.get_country is @frappe.whitelist(allow_guest=True) and, for every
# client IP it has not seen, makes an outbound call to a third-party geo-IP
# service and caches the answer in a module-global dict that is never evicted.
# Unauthenticated, that is an outbound-request amplifier and unbounded memory
# growth in a long-lived worker, and the cache is not site-scoped. Finding 4 in
# docs/SECURITY-BASELINE.md.
#
# Blocking the HTTP route costs nothing here: no shipped frontend calls it. Its
# real use is as a Jinja method (hooks.py `jinja.methods`), which runs inside the
# template engine and never touches this route. If a tenant ever adds client code
# that needs it, change this to a rate limit rather than deleting it.
NGINX_CONF="${BENCH_DIR}/config/nginx.conf"
NGINX_MARKER="# berp-hrms: block unauthenticated geo-IP endpoint"

if grep -qF "${NGINX_MARKER}" "${NGINX_CONF}"; then
	log "  already blocked in ${NGINX_CONF}"
else
	cp -a "${NGINX_CONF}" "${NGINX_CONF}.berp-bak"
	python3 - "${NGINX_CONF}" "${NGINX_MARKER}" <<'PYEOF'
import pathlib, re, sys

path, marker = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()

block = (
	"\n\t" + marker + "\n"
	"\tlocation = /api/method/berp_hrms.utils.get_country {\n"
	"\t\treturn 404;\n"
	"\t}\n"
)

# bench emits one `root .../sites;` line per server block for this site, so
# anchoring there puts the rule in each of them - including the TLS server
# certbot later clones from the plain one.
pattern = re.compile(r"^[ \t]*root[ \t]+\S*/sites;[ \t]*$", re.MULTILINE)
count = len(pattern.findall(text))
if not count:
	sys.exit("no `root .../sites;` anchor in the generated nginx config")

path.write_text(pattern.sub(lambda m: m.group(0) + block, text))
print(f"  inserted into {count} server block(s)")
PYEOF

	# A broken nginx config takes the site down, so prove it parses and put the
	# original back if it does not.
	if ! nginx -t; then
		mv -f "${NGINX_CONF}.berp-bak" "${NGINX_CONF}"
		die "the geo-IP block broke the nginx config; the original has been restored"
	fi
fi

log "Hardening the site for production"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' set-config developer_mode 0"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' set-config host_name 'https://${DOMAIN}'"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' enable-scheduler"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' clear-cache"
# Frappe's own maintenance/backup cron entries.
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench setup-backups" || warn "bench setup-backups failed; configure backups manually"

# ---------------------------------------------------------------------------
# Security assertions
# ---------------------------------------------------------------------------
# Setting a value is not the same as holding it. These re-read the config that
# frappe will actually see and stop the deploy if it is wrong, so a later
# `bench set-config` or a hand-edited file cannot quietly leave a tenant open.
log "Asserting the security configuration"
python3 - "${BENCH_DIR}/sites/common_site_config.json" \
	"${BENCH_DIR}/sites/${SITE_NAME}/site_config.json" <<'PYEOF'
import json, pathlib, sys


def load(path):
	p = pathlib.Path(path)
	if not p.exists():
		return {}
	try:
		return json.loads(p.read_text() or "{}")
	except json.JSONDecodeError as exc:
		sys.exit(f"{p} is not valid JSON: {exc}")


common, site = load(sys.argv[1]), load(sys.argv[2])
problems = []


def effective(key, default=None):
	"""frappe layers site_config over common_site_config; the site wins."""
	return site.get(key, common.get(key, default))


# developer_mode gates berp_hrms.www.berp_hrms.get_context_for_dev, which returns the full
# boot payload to an unauthenticated caller and is guarded by nothing else.
# Finding 3 in docs/SECURITY-BASELINE.md.
# A string "0" is truthy to Python and so to frappe, so it is NOT treated as off.
if effective("developer_mode", 0) not in (0, False, None):
	problems.append(
		"developer_mode is on. It exposes berp_hrms.www.berp_hrms.get_context_for_dev, an "
		"unauthenticated endpoint returning the whole boot payload."
	)

# An ip-api key turns berp_hrms.utils.get_country's unauthenticated outbound calls
# into billable ones. The endpoint is blocked at nginx above; leaving the key
# unset means nothing bills even if that block is ever removed.
for name, cfg in (("site_config.json", site), ("common_site_config.json", common)):
	if "ip-api-key" in cfg:
		problems.append(
			f"ip-api-key is set in {name}. berp_hrms.utils.get_country is unauthenticated "
			"and calls a paid API once per unseen client IP."
		)

if problems:
	for problem in problems:
		print(f"  - {problem}")
	sys.exit("the site is not configured safely for an internet-facing host")

print("  developer_mode off, no ip-api-key: ok")
PYEOF

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
