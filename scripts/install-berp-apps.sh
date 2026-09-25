#!/usr/bin/env bash
#
# Assemble the bERP application stack onto an existing bench, create the site,
# install the apps onto it and build assets.
#
# Shared by scripts/deploy-dev.sh and scripts/deploy-production.sh so the two
# cannot drift: a bench that differs between environments is the bug this
# script exists to prevent.
#
# Expects a bench that already exists - run setup-bench.sh with BENCH_ONLY=1
# first. Every stage is skipped when already satisfied, so re-running is safe.
#
# Required:  BENCH_USER  BENCH_DIR  SITE_NAME  ADMIN_PASSWORD  DB_ROOT_PASSWORD
#
set -euo pipefail

: "${BENCH_USER:?BENCH_USER is required}"
: "${BENCH_DIR:?BENCH_DIR is required}"
: "${SITE_NAME:?SITE_NAME is required}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required}"

# bstBizEra/bERP is a fork of ERPNext - its pyproject declares
# `name = "erpnext"` - so it occupies the bench's `erpnext` app slot.
# Installing upstream frappe/erpnext instead yields a bench without the bERP
# base, and the two cannot coexist: they are the same app.
BERP_REPO="${BERP_REPO:-https://github.com/bstBizEra/bERP.git}"
BERP_BRANCH="${BERP_BRANCH:-dev_branding_lao_hrms_crm}"
HRMS_REPO="${HRMS_REPO:-https://github.com/bstBizEra/bERP-HRMS.git}"
HRMS_BRANCH="${HRMS_BRANCH:-main}"
CRM_REPO="${CRM_REPO:-https://github.com/bstBizEra/bERP-CRM.git}"
CRM_BRANCH="${CRM_BRANCH:-main}"

# Apps that live as subdirectories of the bERP repo rather than as their own
# repositories. bench get-app cannot clone a subdirectory.
BERP_SUBAPPS="${BERP_SUBAPPS:-berp_branding berp_lao}"

SRC_DIR="${SRC_DIR:-$(getent passwd "${BENCH_USER}" | cut -d: -f6)/src}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

as_bench() { su - "${BENCH_USER}" -c "$1"; }

[[ -d "${BENCH_DIR}/apps" && -d "${BENCH_DIR}/sites" ]] \
	|| die "no bench at ${BENCH_DIR} (apps/ and sites/ not found) - run setup-bench.sh with BENCH_ONLY=1 first"

as_bench "mkdir -p '${SRC_DIR}'"

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
	as_bench "rm -rf '${stage}' && git clone -q --depth 1 --branch '${branch}' '${url}' '${stage}'"
	as_bench "cd '${BENCH_DIR}' && bench get-app --skip-assets '${stage}'"
	as_bench "cd '${BENCH_DIR}/apps/${app}' && git remote set-url origin '${url}'"
}

log "Installing erpnext from bERP (${BERP_BRANCH})"
get_git_app erpnext "${BERP_REPO}" "${BERP_BRANCH}"

log "Installing berp_hrms (${HRMS_BRANCH})"
get_git_app berp_hrms "${HRMS_REPO}" "${HRMS_BRANCH}"

log "Installing crm (${CRM_BRANCH})"
get_git_app crm "${CRM_REPO}" "${CRM_BRANCH}"

log "Installing bERP sub-apps: ${BERP_SUBAPPS}"
# Reuse the erpnext checkout rather than cloning bERP a second time.
BERP_SRC="${BENCH_DIR}/apps/erpnext"
command -v rsync >/dev/null || apt-get install -y -qq rsync
for app in ${BERP_SUBAPPS}; do
	[[ -f "${BERP_SRC}/${app}/pyproject.toml" ]] \
		|| die "${BERP_SRC}/${app} is not an app (no pyproject.toml) - is ${BERP_BRANCH} the right branch?"
	[[ -f "${BERP_SRC}/${app}/${app}/hooks.py" ]] \
		|| die "${BERP_SRC}/${app}/${app}/hooks.py missing - wrong tree?"

	as_bench "mkdir -p '${BENCH_DIR}/apps/${app}'"
	as_bench "rsync -a --delete --exclude '.git' --exclude '__pycache__' --exclude 'node_modules' \
		'${BERP_SRC}/${app}/' '${BENCH_DIR}/apps/${app}/'"
	as_bench "'${BENCH_DIR}/env/bin/pip' install --quiet --upgrade -e '${BENCH_DIR}/apps/${app}'"
	# bench reads apps.txt to know what exists; get-app would have written it.
	as_bench "grep -qxF '${app}' '${BENCH_DIR}/sites/apps.txt' 2>/dev/null \
		|| echo '${app}' >> '${BENCH_DIR}/sites/apps.txt'"
done

log "Creating site ${SITE_NAME}"
if [[ ! -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]; then
	as_bench "cd '${BENCH_DIR}' && bench new-site '${SITE_NAME}' \
		--db-root-username root \
		--db-root-password '${DB_ROOT_PASSWORD}' \
		--admin-password '${ADMIN_PASSWORD}' \
		--set-default"
else
	echo "site already exists, skipping"
fi

# erpnext first: berp_branding and berp_lao both declare it in required_apps.
log "Installing apps onto ${SITE_NAME}"
for app in erpnext berp_hrms crm ${BERP_SUBAPPS}; do
	as_bench "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' list-apps | grep -qw '${app}'" \
		&& { echo "${app} already installed on the site"; continue; }
	as_bench "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' install-app '${app}'"
done

log "Building assets"
as_bench "cd '${BENCH_DIR}' && bench build"
