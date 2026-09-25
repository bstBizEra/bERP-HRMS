# Workflows

These were inherited wholesale from [frappe/hrms](https://github.com/frappe/hrms)
`version-16` when this line was cut. Several of them existed to operate
*upstream's* project — publishing upstream releases, pushing to upstream
branches, opening pull requests against `frappe/hrms` — and were removed rather
than repaired.

## Kept

| Workflow | Trigger | Purpose |
|---|---|---|
| `ci.yml` | PR, nightly | Full berp_hrms test suite across 3 containers |
| `ci_faux.yml` | PR touching only docs/assets | Reports the same check names as green, so doc-only PRs are not blocked |
| `patch.yml` | PR, manual | Migration patches against a v14 dataset, stepped up through v15 and v16 |
| `patch_faux.yml` | PR touching only docs/assets | Companion to the above |
| `linters.yml` | PR | Frappe Linter and commitlint (`Semantic Commits`) |
| `docs_checker.yml` | PR | Requires a docs reference on feature PRs (job is named `build`) |
| `labeller.yml` | PR opened/reopened | Applies labels from `.github/labeler.yml` |
| `run-individual-tests.yml` | manual | Run a single test module on demand |

Note that all of these except `run-individual-tests.yml` are `pull_request`
triggered. **A push to this branch with no pull request open runs nothing.**

## Removed

| Workflow | Why |
|---|---|
| `build-and-commit-assets.yml` | Held `contents: write` and **pushed commits** to `develop` / `version-*`, and uploaded build output to upstream's releases. |
| `build_image.yml` | Published container images to upstream's registry on release. |
| `initiate_release.yml` | Opened weekly release pull requests **against `frappe/hrms` itself** (hard-coded `owner: frappe`), not this repository. |
| `on_release.yml` | Semantic-release automation triggered by pushes to `version-14`. |
| `release_notes.yml` | Rewrote release notes for upstream's release process. |
| `generate-pot-file.yml` | Held `contents: write` and pushed regenerated translation files to a `develop` branch weekly. |
| `stale.yml` | Auto-closed issues and pull requests on upstream's staleness policy. |

If this repository later runs its own releases, translation pipeline or
staleness policy, write workflows for it deliberately rather than restoring
these — they encode upstream's branch names, registries and repository.

## Branch resolution

Two places derive an upstream branch from the branch under test.
`.github/helper/install.sh` picks the branch of `frappe`, `erpnext` and
`payments` to clone:

```sh
githubbranch=${GITHUB_BASE_REF:-${GITHUB_REF##*/}}
```

On this branch that resolves to `version-16`, which every upstream repository
has, so no mapping is needed and none is applied. (The `main` line carries a
`main` → `develop` mapping here, because no upstream Frappe repository has a
`main` branch. That mapping is deliberately absent from this branch.)

`patch.yml` does the same in its "Updating to latest version" step, and likewise
uses the branch name verbatim.

## What `patch.yml` had to change

The v14 database dump the patch test restores is a site with **upstream `hrms`**
installed, and this repository's app is `berp_hrms`. Left as inherited, the
workflow would check upstream's `hrms` tree out into a directory called
`apps/berp_hrms` and then `pip install -e` a distribution named `hrms` from it.

It now clones upstream `hrms` alongside, runs the `version-15-hotfix` and
`version-16-hotfix` legs against that, swaps in this repository through
`bench --site test_site rename-from-hrms`, drops upstream `hrms`, and only then
migrates onto this branch's code. That is the upgrade path a real site takes,
which is what makes the test still mean something after the rename.

One detail worth keeping: bench writes `sites/apps.txt` **without a trailing
newline**, so appending with `echo >>` joins onto the previous app's name and the
bench then tries to import a module called `erpnexthrms`. The workflow rewrites
the file with `awk 'NF'` instead.

## Merging from upstream

These files diverge from `frappe/hrms`, so `git merge upstream/version-16` may
conflict here. The deletions are intentional: when a removed workflow reappears
in a merge, delete it again rather than taking upstream's copy.
