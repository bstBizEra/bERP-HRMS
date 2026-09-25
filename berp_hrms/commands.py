"""bench commands this app registers.

There is one, and it exists because the rename migration cannot be reached any
other way. The usual route -- `bench --site <site> execute <dotted.path>` --
resolves the path through frappe.get_attr, which raises AppNotInstalledError
unless the app is already in the site's installed-apps list. That list is
exactly what the migration rewrites, so the check can never be satisfied
beforehand.

bench discovers commands from `sites/apps.txt` instead, which the filesystem
half of the rename has already updated by the time this runs. See
docs/RENAME_TO_BERP_HRMS.md.
"""

import click

import frappe
from frappe.commands import get_site, pass_context


@click.command("rename-from-hrms")
@pass_context
def rename_from_hrms(context):
	"""Rewrite a site's stored state from the `hrms` app to `berp_hrms`."""
	from berp_hrms.rename_migration import execute

	site = get_site(context)
	frappe.init(site=site)
	frappe.connect()
	try:
		execute()
	finally:
		frappe.destroy()


commands = [rename_from_hrms]
