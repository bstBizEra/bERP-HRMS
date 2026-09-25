# Renaming the app: `hrms` → `berp_hrms`

This module used to install into a bench as `hrms`, the name it carries
upstream. It now installs as **`berp_hrms`**.

Two audiences for this document:

- **Operating an existing bench** — the site's database still says `hrms`, and
  nothing on disk tells it otherwise. [The runbook](#runbook-for-an-existing-site)
  below is the in-place upgrade.
- **Merging from upstream** — the rename is the reason upstream merges now
  conflict across the whole tree. [The substitution rule](#the-substitution-rule)
  is what to re-apply to the incoming side.

## What the rename covers

| Renamed | Example |
|---|---|
| Python package | `hrms/` → `berp_hrms/` |
| Distribution name | `pyproject.toml` `name` |
| `app_name` in `hooks.py` | `"hrms"` → `"berp_hrms"` |
| Every import and dotted path | `hrms.hr.utils` → `berp_hrms.hr.utils` |
| Patch paths | `hrms.patches.v16_0.*` → `berp_hrms.patches.v16_0.*` |
| Asset URLs | `/assets/hrms/…` → `/assets/berp_hrms/…` |
| Desk bundles | `hrms.bundle.js` / `.scss` → `berp_hrms.bundle.*` |
| Realtime and cache keys | `hrms:my_leaves` → `berp_hrms:my_leaves` |
| PWA route | `/hrms` → `/berp_hrms`, `www/hrms.py` → `www/berp_hrms.py` |
| `"app"` on fixtures | Dock, Desktop Icon, Workspace, Sidebar JSON |
| Build and deploy tooling | `scripts/`, `docker/`, `.github/`, `docs/` |

Branding follows it as far as the app's own identity: `app_title` is now
**bERP HR**, the publisher is bstBizEra, and the PWA manifest and page title
match. Product copy inside the application — Desktop Icon labels, workspace
content, translations that read "Frappe HR" — is deliberately **not** in this
change. It is data with its own migration cost, and it is a separate pass.

The licence does not change. This is still GPL-3.0 software derived from
[frappe/hrms](https://github.com/frappe/hrms); see [`NOTICE`](../NOTICE).

## The substitution rule

Every lowercase `hrms` token in the application tree became `berp_hrms`, with
four exceptions:

| Kept as `hrms` | Why |
|---|---|
| `github.com/frappe/hrms` | Upstream's URL, not ours |
| `[org_name]/hrms` | A commented-out example in `config/docs.py` |
| `sk_hrms` | A site-config key read from existing `site_config.json` |
| `[frappe.hrms]` | Upstream's Crowdin project id, in `locale/*.po` headers |

Outside the application tree, three more were kept: `berp-hrms` (the
repository slug and the nginx marker in `deploy-production.sh`),
`dev_branding_lao_hrms_crm` (a branch name in `bstBizEra/bERP`), and the
`.github/hrms-*.png` screenshots. The local development site name moved from
`hrms.localhost` to `berp.localhost` rather than to a hostname with an
underscore in it.

Reproducing the rule on an incoming upstream merge:

```bash
perl -0777 -pi -e '
  s{github\.com/frappe/hrms}{\x01U\x01}g;
  s{\[org_name\]/hrms}{\x01O\x01}g;
  s{sk_hrms}{\x01S\x01}g;
  s{\[frappe\.hrms\]}{\x01C\x01}g;
  s{hrms}{berp_hrms}g;
  s{\x01U\x01}{github.com/frappe/hrms}g;
  s{\x01O\x01}{[org_name]/hrms}g;
  s{\x01S\x01}{sk_hrms}g;
  s{\x01C\x01}{[frappe.hrms]}g;
' $(git diff --name-only --diff-filter=ACM upstream/develop)
```

Then move any file whose own name carries the app identity: the package
directory, `public/js/hrms.bundle.js`, `public/scss/hrms.bundle.scss`,
`dock/hrms/hrms.json` and `www/hrms.py`.

## Runbook for an existing site

A site that already has `hrms` installed does **not** pick the new name up from
a `git pull`. Frappe keys stored state on the app name: the installed-apps list,
`Module Def.app_name`, the recorded patch names, scheduled job methods, and the
`app` column on Dock / Workspace / Sidebar / Desktop Icon rows. Change the
filesystem alone and the site either fails to boot or silently re-runs every
patch this app has ever shipped.

Take a backup you have actually restored from before starting. This is not
reversible from inside the application.

```bash
BENCH=/srv/berp/deployments/dev          # or /home/frappe/frappe-bench
SITE=dev.berp.bizera.la

cd "$BENCH"

# 1. Backup, and stop serving.
bench --site "$SITE" backup --with-files
sudo systemctl stop berp-dev             # or: supervisorctl stop all

# 2. Bring the renamed code down, still in the old directory.
git -C apps/hrms fetch origin main
git -C apps/hrms checkout -f origin/main

# 3. Move the app directory. bench requires it to match the app name.
mv apps/hrms apps/berp_hrms
sed -i 's/^hrms$/berp_hrms/' sites/apps.txt

# 4. Reinstall the Python package under its new distribution name.
./env/bin/pip uninstall -y hrms
bench pip install -e ./apps/berp_hrms

# 5. Rewrite the database to match. Prints what it changed.
bench --site "$SITE" execute berp_hrms.rename_migration.execute

# 6. Normal post-change sequence.
bench --site "$SITE" migrate
bench build
bench --site "$SITE" clear-cache

sudo systemctl start berp-dev
```

Step 5 is [`berp_hrms/rename_migration.py`](../berp_hrms/rename_migration.py).
It is idempotent, so a re-run after a failure is safe. It deliberately does
**not** rewrite the site's own customisations — Server Scripts, Client Scripts,
Notifications, Print Formats, Reports, Custom Fields and Property Setters that
call into `hrms.*`. It lists them instead, at the end of its output. Those are
the site owner's code, and each one needs a decision rather than a substitution.

Once it is green, confirm:

```bash
bench --site "$SITE" list-apps            # berp_hrms, not hrms
bench --site "$SITE" execute 'frappe.get_installed_apps'
ls apps/berp_hrms/berp_hrms/hooks.py
```

### If it goes wrong

Restore the backup from step 1 onto a site created from the pre-rename code.
There is no partial rollback: once `Module Def.app_name` and `Patch Log` have
been rewritten, the database belongs to `berp_hrms`.

## What this costs

**Upstream merges now conflict across the tree.** `git merge upstream/develop`
touches every file that names the package, which is most of them. The history
is still shared — the import preserved it, and the merge base is real — so the
merge is resolvable, but it is a substitution pass rather than a fast-forward.
Budget for it on every sync.

**`patch.yml` tests the migration, not just the patches.** The v14 database
dump that CI restores has upstream `hrms` installed, so the workflow now steps
that site up through upstream's version-15 and version-16, runs
`berp_hrms.rename_migration.execute`, and only then migrates onto this
repository's code. That is the same path a real site takes, which is the point.
