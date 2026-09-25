# Renaming the app: `hrms` → `berp_hrms`

This module used to install into a bench as `hrms`, the name it carries
upstream. It now installs as **`berp_hrms`**.

This is the **`berp_hrms/version-16`** line, cut from upstream `frappe/hrms`
`version-16` at `7e0fba4bf` (16.19.0). Not to be confused with this repository's
`version-16` branch, which keeps `app_name = "hrms"` on purpose and needs no
migration at all. The rename rule below is identical to the one the
`main` line uses — only the branch names differ. See
[VERSION-16.md](VERSION-16.md) for what this line is for.

Two audiences for this document:

- **Operating an existing bench** — the site's database still says `hrms`, and
  nothing on disk tells it otherwise. [The runbook](#runbook-for-an-existing-site)
  below is the in-place upgrade.
- **Merging from upstream `version-16`** — the rename is the reason upstream merges
  now conflict across the whole tree. [The substitution rule](#the-substitution-rule)
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

Outside the application tree three more were kept — `berp-hrms` (this
repository's slug), `dev_branding_lao_hrms_crm` (a branch name in
`bstBizEra/bERP`), and the `.github/hrms-*.png` screenshots — along with the
root `hrms.png` and the whole of `.github/helper/documentation.py`, which only
ever names upstream's own repository. Any `hrms.localhost` site name became
`berp.localhost` rather than a hostname with an underscore in it.

The rename lengthens dotted paths, which pushes some import blocks and call
expressions past the widths the repository configures. Re-run its own formatters
afterwards — `ruff check --fix`, `ruff format` and `prettier`, at the versions
`.pre-commit-config.yaml` pins — or `Frappe Linter` fails on formatting alone.

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
' $(git diff --name-only --diff-filter=ACM upstream/version-16)
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
BENCH=/home/frappe/frappe-bench          # wherever the bench actually is
SITE=<your site>

cd "$BENCH"

# 1. Backup, and stop serving.
bench --site "$SITE" backup --with-files
supervisorctl stop all                   # or stop whatever runs this bench

# 2. Bring the renamed code down, still in the old directory.
git -C apps/hrms fetch origin berp_hrms/version-16
git -C apps/hrms checkout -f origin/berp_hrms/version-16

# 3. Move the app directory. bench requires it to match the app name.
mv apps/hrms apps/berp_hrms
sed -i 's/^hrms$/berp_hrms/' sites/apps.txt

# 4. Reinstall the Python package under its new distribution name.
./env/bin/pip uninstall -y hrms
bench pip install -e ./apps/berp_hrms

# 5. Rewrite the database to match. Prints what it changed.
bench --site "$SITE" rename-from-hrms

# 6. Normal post-change sequence.
bench --site "$SITE" migrate
bench build
bench --site "$SITE" clear-cache

supervisorctl start all
```

Step 3 has to move the directory rather than leave it: bench derives an app's
name from its directory basename, and the two must agree.

Step 5 runs [`berp_hrms/rename_migration.py`](../berp_hrms/rename_migration.py)
through a bench command registered in
[`berp_hrms/commands.py`](../berp_hrms/commands.py). It is a command rather than
a `bench execute` because `bench execute` resolves its dotted path through
`frappe.get_attr`, which refuses with `AppNotInstalledError` until `berp_hrms`
is in the site's installed-apps list — and that list is one of the things this
migration writes. bench finds commands through `sites/apps.txt`, which step 3
has already updated.

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

**Upstream merges now conflict across the tree.** `git merge upstream/version-16`
touches every file that names the package, which is most of them. The history
is still shared — the import preserved it, and the merge base is real — so the
merge is resolvable, but it is a substitution pass rather than a fast-forward.
Budget for it on every sync.

**`patch.yml` tests the migration, not just the patches.** The v14 database
dump that CI restores has upstream `hrms` installed. Left alone after the rename,
the workflow would check upstream's `hrms` tree out into a directory called
`apps/berp_hrms` and install a distribution named `hrms` from it. It instead
clones upstream `hrms` alongside, steps the site up through upstream's
`version-15-hotfix` and `version-16-hotfix`, runs
`bench --site test_site rename-from-hrms`, drops upstream `hrms`, and only then
migrates onto this branch's code. That is the same path a real site takes, which
is the point.
