# Workflows

These were inherited wholesale from [frappe/hrms](https://github.com/frappe/hrms)
when this repository was seeded. Several of them existed to operate *upstream's*
project — publishing upstream releases, pushing to upstream branches, opening
pull requests against `frappe/hrms` — and were removed rather than repaired.

## Kept

| Workflow | Trigger | Purpose |
|---|---|---|
| `ci.yml` | PR, nightly | Full hrms test suite across 3 containers |
| `ci_faux.yml` | PR touching only docs/assets | Reports the same check names as green, so doc-only PRs are not blocked |
| `patch.yml` | PR, nightly | Runs migration patches against a v15 dataset |
| `patch_faux.yml` | PR touching only docs/assets | Companion to the above |
| `linters.yml` | PR | Frappe Linter and commitlint (`Semantic Commits`) |
| `docs_checker.yml` | PR | Requires a docs reference on feature PRs (job is named `build`) |
| `labeller.yml` | PR opened/reopened | Applies labels from `.github/labeler.yml` |
| `run-individual-tests.yml` | manual | Run a single test module on demand |

## Removed

| Workflow | Why |
|---|---|
| `build-and-commit-assets.yml` | Held `contents: write` and **pushed commits** to `develop` / `version-*`, and uploaded build output to upstream's releases. Neither branch exists here. |
| `build_image.yml` | Published container images to upstream's registry on release. |
| `initiate_release.yml` | Opened weekly release pull requests **against `frappe/hrms` itself** (hard-coded `owner: frappe`), not this repository. |
| `on_release.yml` | Semantic-release automation triggered by pushes to `version-14`. |
| `release_notes.yml` | Rewrote release notes for upstream's release process. |
| `generate-pot-file.yml` | Held `contents: write` and pushed regenerated translation files to a `develop` branch weekly. |
| `review-translation-changes.yaml` | Reviewed Crowdin translation PRs against upstream's translation project. |
| `stale.yml` | Auto-closed issues and pull requests on upstream's staleness policy. |

If this repository later runs its own releases, translation pipeline or
staleness policy, write workflows for it deliberately rather than restoring
these — they encode upstream's branch names, registries and repository.

## The `main` / `develop` mapping

Two places derive an upstream branch from the branch under test.
`.github/helper/install.sh` picks the branch of `frappe`, `erpnext` and
`payments` to clone:

```sh
githubbranch=${GITHUB_BASE_REF:-${GITHUB_REF##*/}}
```

Upstream's default branch is `develop`, so that resolves correctly there. This
repository's default branch is `main`, and **none of the upstream repositories
have a `main` branch** — so without a mapping CI clones a ref that does not
exist, `set -e` aborts, and every job dies during setup before a single test
runs. The installer therefore maps `main` to `develop`.

`patch.yml` does the same thing again in its "Updating to latest version"
step, fetching `${GITHUB_BASE_REF}` from `frappe/frappe`, and carries the
same mapping.

`version-*` branches pass through untouched in both places, so release
branches keep working if any are added later. (`ci.yml` also sets an
`HR_BRANCH` environment variable from `github.base_ref`, but nothing reads
it; it is left as inherited.)

## Merging from upstream

These files diverge from `frappe/hrms`, so `git merge upstream/develop` may
conflict here. The deletions are intentional: when a removed workflow
reappears in a merge, delete it again rather than taking upstream's copy.
