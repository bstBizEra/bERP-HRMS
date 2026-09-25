#!/usr/bin/env bash
#
# Container entrypoint: provision the bench on first run, then start it.
# Re-running is cheap - every stage is skipped if it is already done.
set -euo pipefail

SITE_NAME="${SITE_NAME:-berp.localhost}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}"
ERPNEXT_BRANCH="${ERPNEXT_BRANCH:-develop}"
PYTHON_VERSION="${PYTHON_VERSION:-3.14}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

BENCH_DIR="/home/frappe/frappe-bench"
REPO="/workspace"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

if [[ -d "${BENCH_DIR}/apps/frappe" ]]; then
	log "Bench already provisioned - starting"
	cd "${BENCH_DIR}"
	exec bench start
fi

PYTHON_BIN="$(uv python find "${PYTHON_VERSION}" | tail -1)"
log "Initialising bench with ${PYTHON_BIN}"
cd /home/frappe
bench init frappe-bench \
	--python "${PYTHON_BIN}" \
	--frappe-branch "${FRAPPE_BRANCH}" \
	--skip-redis-config-generation \
	--skip-assets

cd "${BENCH_DIR}"

log "Pointing bench at the mariadb and redis services"
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Redis runs as its own service, and the asset watcher is noisy in a
# container; drop both from the Procfile.
sed -i '/redis/d' ./Procfile
sed -i '/watch/d' ./Procfile

log "Installing erpnext (berp_hrms declares it in required_apps)"
bench get-app --skip-assets --branch "${ERPNEXT_BRANCH}" erpnext

log "Installing berp_hrms from the mounted repository"
# Staged as `berp_hrms` because bench names the app after the directory basename.
mkdir -p /home/frappe/src
git config --global --add safe.directory "${REPO}"
git config --global --add safe.directory "${REPO}/.git"
rm -rf /home/frappe/src/berp_hrms
git clone -q "${REPO}" /home/frappe/src/berp_hrms
bench get-app --skip-assets /home/frappe/src/berp_hrms
rm -rf /home/frappe/src/berp_hrms

log "Creating site ${SITE_NAME}"
bench new-site "${SITE_NAME}" \
	--db-root-username root \
	--db-root-password "${DB_ROOT_PASSWORD}" \
	--admin-password "${ADMIN_PASSWORD}" \
	--set-default

bench --site "${SITE_NAME}" install-app erpnext berp_hrms
bench --site "${SITE_NAME}" set-config developer_mode 1
bench --site "${SITE_NAME}" enable-scheduler
bench --site "${SITE_NAME}" clear-cache
bench use "${SITE_NAME}"

log "Building assets"
bench build

log "Starting bench - http://localhost:8000 (Administrator / ${ADMIN_PASSWORD})"
exec bench start
