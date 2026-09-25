"""In-place migration of an existing site from the `hrms` app to `berp_hrms`.

Frappe keys a great deal of stored state on the app name: the `installed_apps`
global, the Installed Applications record beside it, which app owns each Module
Def, which patches have already run, the dotted paths of scheduled jobs, and the
`app` column on Dock / Workspace / Sidebar / Desktop Icon records. Renaming the
package on disk changes none of that, so a site that had `hrms` installed will
fail to boot -- or silently re-run every patch -- until the database is updated
to match.

This is the database half of the rename. The filesystem half (moving
`apps/hrms` to `apps/berp_hrms`, rewriting `sites/apps.txt` and reinstalling the
Python package) happens before it; see docs/RENAME_TO_BERP_HRMS.md for the full
runbook.

Run it once per site, after the app directory has been moved:

    bench --site <site> rename-from-hrms

That command is registered in berp_hrms/commands.py. `bench execute` cannot
reach this module: it resolves the dotted path through frappe.get_attr, which
refuses with AppNotInstalledError until `berp_hrms` is in the site's
installed-apps list -- which is one of the things this migration writes.

It is idempotent: re-running it on an already-migrated site is a no-op, and it
prints what it changed rather than working silently.

Everything here goes through the query builder rather than raw SQL. The table
and column names are internal constants, but a migration that rewrites
installed-app state is the last place to hand-assemble a query string.
"""

import json

import frappe

OLD_APP = "hrms"
NEW_APP = "berp_hrms"

# Doctypes whose rows carry code as data. These are scanned and reported rather
# than rewritten: a customisation that calls into the app is the site owner's
# code, and rewriting it unreviewed is how a migration eats someone's work.
CODE_BEARING = {
	"Server Script": ("script",),
	"Client Script": ("script",),
	"Notification": ("condition", "message"),
	"Print Format": ("html",),
	"Report": ("report_script", "javascript", "query"),
	"Custom Field": ("options", "fetch_from", "depends_on"),
	"Property Setter": ("value",),
	"Dashboard Chart": ("source",),
}


def execute():
	site = frappe.local.site

	if not _has_old_state():
		print(f"Nothing to do: no {OLD_APP!r} state found on {site}.")
		_report_code_bearing()
		return

	print(f"Migrating {site}: {OLD_APP} -> {NEW_APP}")

	_rewrite_app_globals()
	_rename_installed_app()
	_rename_module_defs()
	_rewrite_dotted_paths("Patch Log", "patch")
	_rewrite_dotted_paths("Scheduled Job Type", "method")
	_rename_app_columns()
	_rename_dock()

	# This runs as a one-shot `bench execute`, not inside a request, so nothing
	# else will commit for us and a half-applied rename leaves the site
	# unbootable.
	frappe.db.commit()  # nosemgrep
	frappe.clear_cache()

	print("\nDatabase migration complete. Still to run, in this order:")
	print(f"    bench --site {site} migrate")
	print("    bench build")
	print(f"    bench --site {site} clear-cache")

	_report_code_bearing()


def _table(doctype: str):
	return frappe.qb.DocType(doctype)


def _has_old_state() -> bool:
	if OLD_APP in _app_list_global("installed_apps"):
		return True

	installed = _table("Installed Application")
	module_def = _table("Module Def")

	has_installed = (
		frappe.qb.from_(installed).select(installed.name).where(installed.app_name == OLD_APP).limit(1).run()
	)
	has_modules = (
		frappe.qb.from_(module_def)
		.select(module_def.name)
		.where(module_def.app_name == OLD_APP)
		.limit(1)
		.run()
	)
	return bool(has_installed or has_modules)


def _app_list_global(key: str) -> list[str]:
	try:
		value = json.loads(frappe.db.get_global(key) or "[]")
	except (TypeError, ValueError):
		return []
	return value if isinstance(value, list) else []


def _rewrite_app_globals():
	"""Rewrite the global JSON lists that name apps.

	This is the one that matters most. `frappe.get_installed_apps()` does not read
	the `Installed Application` table -- that carries version and branch metadata
	beside the real list -- it reads a JSON list stored as a global:

	    installed = orjson.loads(frappe.db.get_global("installed_apps") or "[]")

	Leave that naming `hrms` and the next `bench migrate` dies in
	`sync_module_defs` with `ModuleNotFoundError: No module named 'hrms'`, long
	after everything else looks migrated.

	Every global holding a list with `hrms` in it is rewritten rather than a
	hard-coded few, so `disabled_apps`, `setup_wizard_completed_apps` and
	whatever Frappe adds next are covered. The match is on a whole element, not a
	substring, so a global that merely mentions the word is left alone.
	"""
	table = _table("DefaultValue")
	rows = (
		frappe.qb.from_(table)
		.select(table.defkey, table.defvalue)
		.where(table.parent == "__global")
		.run(as_dict=True)
	)

	changed = 0
	for row in rows:
		try:
			value = json.loads(row.defvalue or "")
		except (TypeError, ValueError):
			continue
		if not isinstance(value, list) or OLD_APP not in value:
			continue

		renamed = []
		for app in value:
			app = NEW_APP if app == OLD_APP else app
			if app not in renamed:
				renamed.append(app)

		frappe.db.set_global(row.defkey, json.dumps(renamed))
		print(f"    {row.defkey}: {value} -> {renamed}")
		changed += 1

	print(f"  app-name globals rewritten: {changed}")


def _names_where_app_is(doctype: str, column: str, value: str) -> list[str]:
	table = _table(doctype)
	return frappe.qb.from_(table).select(table.name).where(table[column] == value).run(pluck=True)


def _rename_installed_app():
	"""Point the Installed Applications record at the new name.

	This is the metadata beside the `installed_apps` global -- app version and
	git branch, shown in the Installed Applications single. It is not what
	frappe.get_installed_apps() reads, but leaving it stale means the site
	reports a version for an app it no longer has.
	"""
	table = _table("Installed Application")
	stale = _names_where_app_is("Installed Application", "app_name", OLD_APP)

	if _names_where_app_is("Installed Application", "app_name", NEW_APP):
		# A fresh install of the renamed app already registered itself; drop the
		# old row rather than ending up with the app listed twice.
		if stale:
			frappe.qb.from_(table).delete().where(table.app_name == OLD_APP).run()
		print(f"  stale Installed Application rows removed: {len(stale)}")
		return

	if stale:
		frappe.qb.update(table).set(table.app_name, NEW_APP).where(table.app_name == OLD_APP).run()
	print(f"  Installed Application rows updated: {len(stale)}")


def _rename_module_defs():
	table = _table("Module Def")
	names = _names_where_app_is("Module Def", "app_name", OLD_APP)
	if names:
		frappe.qb.update(table).set(table.app_name, NEW_APP).where(table.app_name == OLD_APP).run()
	print(f"  Module Def rows re-owned: {len(names)}")


def _rewrite_dotted_paths(doctype: str, field: str):
	"""Rewrite `hrms.x.y` to `berp_hrms.x.y` in a column that stores import paths.

	Patch Log holds the dotted path exactly as patches.txt spells it -- leave the
	old spelling and every patch this app has ever shipped runs again on the next
	migrate. Scheduled Job Type holds the path the scheduler resolves at run time.
	"""
	if not frappe.db.exists("DocType", doctype):
		return

	table = _table(doctype)
	rows = (
		frappe.qb.from_(table)
		.select(table.name, table[field])
		.where(table[field].like(f"{OLD_APP}.%"))
		.run(as_dict=True)
	)

	for row in rows:
		renamed = NEW_APP + row[field][len(OLD_APP) :]
		frappe.db.set_value(doctype, row["name"], field, renamed, update_modified=False)

	print(f"  {doctype}.{field} rewritten: {len(rows)}")


def _rename_app_columns():
	"""Update every doctype that records which app a record belongs to.

	Which doctypes those are moves between Frappe versions (Dock and Sidebar are
	recent), so discover them rather than hard-coding a list that silently goes
	stale.
	"""
	total = 0
	for doctype in frappe.get_all("DocType", filters={"issingle": 0, "is_virtual": 0}, pluck="name"):
		try:
			if not frappe.db.has_column(doctype, "app"):
				continue
			names = _names_where_app_is(doctype, "app", OLD_APP)
			if not names:
				continue
			table = _table(doctype)
			frappe.qb.update(table).set(table.app, NEW_APP).where(table.app == OLD_APP).run()
		except Exception as e:  # a table the site never created
			print(f"    skipped {doctype}: {e}")
			continue
		print(f"    {doctype}: {len(names)}")
		total += len(names)
	print(f"  `app` columns updated: {total}")


def _rename_dock():
	"""The Dock record is named after the app, so it needs a document rename."""
	if not frappe.db.exists("DocType", "Dock"):
		return
	if not frappe.db.exists("Dock", OLD_APP):
		return

	if frappe.db.exists("Dock", NEW_APP):
		frappe.delete_doc("Dock", OLD_APP, force=True, ignore_permissions=True)
		print(f"  Dock {OLD_APP!r} deleted ({NEW_APP!r} already exists)")
	else:
		frappe.rename_doc("Dock", OLD_APP, NEW_APP, force=True)
		print(f"  Dock renamed: {OLD_APP} -> {NEW_APP}")


def _report_code_bearing():
	"""Report, without changing, customisations that reference the old app.

	These are the site's own scripts and print formats. A Server Script calling
	`hrms.hr.utils...` will raise after the rename, and the site owner has to
	decide what the new call should be.
	"""
	findings = []
	for doctype, fields in CODE_BEARING.items():
		if not frappe.db.exists("DocType", doctype):
			continue
		table = _table(doctype)
		for field in fields:
			try:
				if not frappe.db.has_column(doctype, field):
					continue
				names = (
					frappe.qb.from_(table)
					.select(table.name)
					.where(table[field].like(f"%{OLD_APP}.%"))
					.limit(25)
					.run(pluck=True)
				)
			except Exception:
				continue
			findings.extend(f"{doctype} / {name} / {field}" for name in names)

	if not findings:
		print(f"\nNo customisation references {OLD_APP!r}.")
		return

	print(f"\nNOT changed -- customisations that still reference {OLD_APP!r}:")
	for line in findings:
		print(f"    {line}")
	print("Review each one; these are the site's own code, not the app's.")
