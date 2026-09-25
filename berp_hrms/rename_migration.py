"""In-place migration of an existing site from the `hrms` app to `berp_hrms`.

Frappe keys a great deal of stored state on the app name: which apps a site has
installed, which app owns each Module Def, which patches have already run, the
dotted paths of scheduled jobs, and the `app` column on Dock / Workspace /
Sidebar / Desktop Icon records. Renaming the package on disk changes none of
that, so a site that had `hrms` installed will fail to boot -- or silently
re-run every patch -- until the database is updated to match.

This is the database half of the rename. The filesystem half (moving
`apps/hrms` to `apps/berp_hrms`, rewriting `sites/apps.txt` and reinstalling the
Python package) happens before it; see docs/RENAME_TO_BERP_HRMS.md for the full
runbook.

Run it once per site, after the app directory has been moved:

    bench --site <site> execute berp_hrms.rename_migration.execute

It is idempotent: re-running it on an already-migrated site is a no-op, and it
prints what it changed rather than working silently.
"""

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

	_rename_installed_app()
	_rename_module_defs()
	_rewrite_dotted_paths("Patch Log", "patch")
	_rewrite_dotted_paths("Scheduled Job Type", "method")
	_rename_app_columns()
	_rename_dock()

	frappe.db.commit()
	frappe.clear_cache()

	print("\nDatabase migration complete. Still to run, in this order:")
	print(f"    bench --site {site} migrate")
	print("    bench build")
	print(f"    bench --site {site} clear-cache")

	_report_code_bearing()


def _has_old_state() -> bool:
	return bool(
		frappe.db.exists("Installed Application", {"app_name": OLD_APP})
		or frappe.db.exists("Module Def", {"app_name": OLD_APP})
	)


def _update(table: str, where: str, write: str, params: dict, label: str) -> int:
	"""Run one write and report how many rows it touched.

	The count is taken before the write rather than from ROW_COUNT(), which is
	connection state and not reliable once frappe has issued anything of its own
	in between.
	"""
	count = frappe.db.sql(f"select count(*) from `{table}` where {where}", params)[0][0]
	if count:
		frappe.db.sql(f"{write} where {where}", params)
	print(f"  {label}: {count}")
	return count


def _rename_installed_app():
	"""Point the site's installed-apps list at the new name.

	`Installed Applications` is a Single whose child rows are keyed on app_name;
	frappe.get_installed_apps() reads them, and an entry naming a package that no
	longer imports makes the site unbootable.
	"""
	if frappe.db.exists("Installed Application", {"app_name": NEW_APP}):
		# A fresh install of the renamed app already registered itself; drop the
		# stale row rather than ending up with the app listed twice.
		_update(
			"tabInstalled Application",
			"app_name = %(old)s",
			"delete from `tabInstalled Application`",
			{"old": OLD_APP},
			"stale Installed Application rows removed",
		)
		return

	_update(
		"tabInstalled Application",
		"app_name = %(old)s",
		"update `tabInstalled Application` set app_name = %(new)s",
		{"old": OLD_APP, "new": NEW_APP},
		"Installed Application rows updated",
	)


def _rename_module_defs():
	_update(
		"tabModule Def",
		"app_name = %(old)s",
		"update `tabModule Def` set app_name = %(new)s",
		{"old": OLD_APP, "new": NEW_APP},
		"Module Def rows re-owned",
	)


def _rewrite_dotted_paths(doctype: str, field: str):
	"""Rewrite `hrms.x.y` to `berp_hrms.x.y` in a column that stores import paths.

	Patch Log holds the dotted path exactly as patches.txt spells it -- leave the
	old spelling and every patch this app has ever shipped runs again on the next
	migrate. Scheduled Job Type holds the path the scheduler resolves at run time.
	"""
	if not frappe.db.exists("DocType", doctype):
		return

	_update(
		f"tab{doctype}",
		f"`{field}` like %(prefix)s",
		f"update `tab{doctype}` set `{field}` = concat(%(new)s, substring(`{field}`, %(cut)s))",
		{"new": NEW_APP, "cut": len(OLD_APP) + 1, "prefix": f"{OLD_APP}.%"},
		f"{doctype}.{field} rewritten",
	)


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
			table = f"tab{doctype}"
			count = frappe.db.sql(f"select count(*) from `{table}` where app = %(old)s", {"old": OLD_APP})[0][
				0
			]
			if not count:
				continue
			frappe.db.sql(
				f"update `{table}` set app = %(new)s where app = %(old)s",
				{"old": OLD_APP, "new": NEW_APP},
			)
		except Exception as e:  # a table the site never created
			print(f"    skipped {doctype}: {e}")
			continue
		print(f"    {doctype}: {count}")
		total += count
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
		for field in fields:
			try:
				if not frappe.db.has_column(doctype, field):
					continue
				rows = frappe.db.sql(
					f"select name from `tab{doctype}` where `{field}` like %(needle)s limit 25",
					{"needle": f"%{OLD_APP}.%"},
				)
			except Exception:
				continue
			findings.extend(f"{doctype} / {name} / {field}" for (name,) in rows)

	if not findings:
		print(f"\nNo customisation references {OLD_APP!r}.")
		return

	print(f"\nNOT changed -- customisations that still reference {OLD_APP!r}:")
	for line in findings:
		print(f"    {line}")
	print("Review each one; these are the site's own code, not the app's.")
