#!/usr/bin/env bash
#
# Provision a Frappe bench running this repository's `hrms` app.
#
# Target: a clean Debian/Ubuntu host (tested on Ubuntu 24.04) where you have
# root. It installs the toolchain, builds the bench, creates a site and
# installs erpnext + hrms onto it.
#
# The toolchain versions below are not arbitrary - see docs/LOCAL_SETUP.md
# for what breaks if you use the distro defaults instead.
#
#   sudo ./scripts/setup-bench.sh
#
set -euo pipefail

BENCH_USER="${BENCH_USER:-frappe}"
BENCH_HOME="${BENCH_HOME:-/home/${BENCH_USER}}"
BENCH_DIR="${BENCH_DIR:-${BENCH_HOME}/frappe-bench}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}"
ERPNEXT_BRANCH="${ERPNEXT_BRANCH:-develop}"
NODE_MAJOR="${NODE_MAJOR:-24}"
PYTHON_VERSION="${PYTHON_VERSION:-3.14}"

# Local-development credentials. Override both before using this anywhere
# that is reachable by anyone other than you.
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-frappe_dev_root}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

if [[ "${EUID}" -ne 0 ]]; then
	echo "Run as root (sudo $0)" >&2
	exit 1
fi

log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
	git curl xz-utils \
	mariadb-server mariadb-client libmariadb-dev \
	redis-server \
	python3-dev python3-venv pkg-config \
	libffi-dev libssl-dev build-essential \
	wkhtmltopdf

log "Configuring MariaDB for Frappe (utf8mb4 / barracuda)"
# Frappe refuses to create a site unless the server charset is utf8mb4.
mkdir -p /etc/mysql/conf.d
cat > /etc/mysql/conf.d/frappe.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb-file-per-table = 1
bind-address = 127.0.0.1

[mysql]
default-character-set = utf8mb4
EOF

# Prefer systemd where it exists; fall back to launching mariadbd directly
# (containers, WSL and CI images frequently have no init system).
if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
	systemctl restart mariadb
else
	mkdir -p /var/run/mysqld /var/log/mysql
	chown -R mysql:mysql /var/run/mysqld /var/log/mysql /var/lib/mysql
	pkill -x mariadbd 2>/dev/null || true
	nohup mariadbd --user=mysql > /var/log/mysql/manual.log 2>&1 &
fi
mariadb-admin --wait=60 --silent ping 2>/dev/null \
	|| mariadb-admin --wait=60 --silent -u root -p"${DB_ROOT_PASSWORD}" ping

log "Setting MariaDB root password"
# bench connects over TCP, so root needs password auth rather than unix_socket.
# On a first run root still authenticates via the unix socket; on a re-run the
# password is already set, so try both rather than aborting under `set -e`.
SET_ROOT_PW_SQL="ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_ROOT_PASSWORD}'); FLUSH PRIVILEGES;"
if mariadb -u root -e "SELECT 1" >/dev/null 2>&1; then
	mariadb -u root -e "${SET_ROOT_PW_SQL}"
elif mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; then
	echo "Root password already set, leaving it alone"
else
	echo "Cannot authenticate to MariaDB as root." >&2
	echo "Set DB_ROOT_PASSWORD to the existing password and re-run." >&2
	exit 1
fi

log "Installing Node ${NODE_MAJOR}"
# frappe v17's package.json sets "engines": { "node": ">=24" }; yarn refuses
# to install under anything older.
if ! /usr/local/node${NODE_MAJOR}/bin/node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
	tarball="$(curl -sS "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
		| grep -oE "node-v${NODE_MAJOR}\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz" | head -1)"
	curl -sSL -o "/tmp/${tarball}" "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${tarball}"
	mkdir -p "/usr/local/node${NODE_MAJOR}"
	tar -xJf "/tmp/${tarball}" -C "/usr/local/node${NODE_MAJOR}" --strip-components=1
	rm -f "/tmp/${tarball}"
fi
# zz- prefix so this wins over any distro nodejs profile script.
cat > /etc/profile.d/zz-bench-node.sh <<EOF
export PATH="/usr/local/node${NODE_MAJOR}/bin:\$PATH"
EOF
chmod 0644 /etc/profile.d/zz-bench-node.sh
"/usr/local/node${NODE_MAJOR}/bin/npm" install -g --silent yarn

log "Creating ${BENCH_USER} user"
# bench refuses to initialise as root.
id "${BENCH_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${BENCH_USER}"

log "Installing bench CLI"
# Install with the interpreter the `bench` entrypoint actually uses, otherwise
# its dependencies land in a different site-packages and every command fails
# with ModuleNotFoundError.
/usr/bin/python3 -m pip install --break-system-packages --upgrade frappe-bench

log "Provisioning Python ${PYTHON_VERSION}"
# frappe v17 pins requires-python >=3.14,<3.15 and uses PEP 695 `type`
# statements, so distro Python (3.12 on Ubuntu 24.04) cannot even parse it.
# uv ships prebuilt CPython, which avoids compiling from source.
su - "${BENCH_USER}" -c "uv python install ${PYTHON_VERSION}"
PYTHON_BIN="$(su - "${BENCH_USER}" -c "uv python find ${PYTHON_VERSION}" | tail -1)"
echo "Using interpreter: ${PYTHON_BIN}"

log "Initialising bench at ${BENCH_DIR}"
if [[ ! -d "${BENCH_DIR}/apps/frappe" ]]; then
	su - "${BENCH_USER}" -c "cd '${BENCH_HOME}' && bench init '$(basename "${BENCH_DIR}")' \
		--python '${PYTHON_BIN}' \
		--frappe-branch '${FRAPPE_BRANCH}' \
		--skip-assets"
else
	echo "Bench already present, skipping init"
fi

log "Installing erpnext (hrms declares it in required_apps)"
if [[ ! -d "${BENCH_DIR}/apps/erpnext" ]]; then
	su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench get-app --skip-assets --branch '${ERPNEXT_BRANCH}' erpnext"
fi

log "Installing hrms from this checkout (${REPO_ROOT})"
# Staged under the name `hrms` because bench derives the app name from the
# directory basename - cloning from a directory called bERP-HRMS registers an
# app of that name and the import fails.
STAGE="${BENCH_HOME}/src/hrms"
if [[ ! -d "${BENCH_DIR}/apps/hrms" ]]; then
	su - "${BENCH_USER}" -c "mkdir -p '${BENCH_HOME}/src'"
	su - "${BENCH_USER}" -c "git config --global --add safe.directory '${REPO_ROOT}'"
	su - "${BENCH_USER}" -c "git config --global --add safe.directory '${REPO_ROOT}/.git'"
	su - "${BENCH_USER}" -c "rm -rf '${STAGE}' && git clone -q '${REPO_ROOT}' '${STAGE}'"
	su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench get-app --skip-assets '${STAGE}'"
	su - "${BENCH_USER}" -c "cd '${BENCH_DIR}/apps/hrms' && git remote set-url upstream https://github.com/bstBizEra/bERP-HRMS.git"
	su - "${BENCH_USER}" -c "rm -rf '${STAGE}'"
fi

log "Creating site ${SITE_NAME}"
if [[ ! -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]; then
	su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench new-site '${SITE_NAME}' \
		--db-root-username root \
		--db-root-password '${DB_ROOT_PASSWORD}' \
		--admin-password '${ADMIN_PASSWORD}' \
		--set-default"
	su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' install-app erpnext hrms"
fi

log "Building assets"
su - "${BENCH_USER}" -c "cd '${BENCH_DIR}' && bench build"

log "Done"
cat <<EOF

  Bench:  ${BENCH_DIR}
  Site:   ${SITE_NAME}
  Login:  Administrator / ${ADMIN_PASSWORD}

  Start it with:
    su - ${BENCH_USER} -c "cd ${BENCH_DIR} && bench start"

  Then open http://${SITE_NAME}:8000
  (add "127.0.0.1 ${SITE_NAME}" to /etc/hosts if it does not resolve)

  The site has not been through the setup wizard yet; it will prompt on
  first login. To complete it non-interactively, see docs/LOCAL_SETUP.md.

EOF
