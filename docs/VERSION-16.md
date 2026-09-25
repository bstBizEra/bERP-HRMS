# The `berp_hrms/version-16` line

## Why it exists

`bERP-HRMS` `main` tracks upstream `develop`. It is `17.0.0-dev` and declares

```toml
[tool.bench.frappe-dependencies]
frappe  = ">=17.0.0-dev,<18.0.0"
erpnext = ">=17.0.0-dev,<18.0.0"
```

bench compares those with `semantic_version`, so that app cannot be installed on
a released v16 bench. Everything bERP actually runs today is released v16:

| Bench | frappe | erpnext | HR app |
|---|---|---|---|
| bERP development VM (`berp-linux`) | **16.33.1** | **16.34.2** | none |
| Tenants | released `version-16` | released `version-16` | upstream `hrms@version-16` |
| bERP development bench (CI `develop` leg) | `develop` 17.0.0-dev | `bstBizEra/bERP` 17.0.0-dev | `berp_hrms` from `main` |

So `main` is installable on exactly one of those three, and it is the one that
does not exist outside CI. That is what this branch fixes.

This line is upstream `frappe/hrms` `version-16` at
[`7e0fba4bf`](https://github.com/frappe/hrms/commit/7e0fba4bf11a63ac7b21a717610e235310815c1a)
(16.19.0), with the same `hrms` → `berp_hrms` rename `main` carries and nothing
else. It declares `frappe >=16.0.0,<17.0.0` and `erpnext >=16.0.0,<17.0.0`, which
16.33.1 / 16.34.2 satisfy.

## What is and is not on this branch

**On it:** the renamed application tree, the bERP app identity (`app_name`,
`app_title`, publisher, `source_link`, PWA manifest, distribution name), the
rename migration and the `bench rename-from-hrms` command that reaches it, the
attribution in [`NOTICE`](../NOTICE), the security baseline, and the CI changes
that make the inherited workflows operate *this* repository.

**Not on it:** `scripts/deploy-dev.sh`, `scripts/deploy-production.sh`,
`scripts/setup-bench.sh`, `scripts/install-berp-apps.sh`, `docs/LOCAL_SETUP.md`,
`docs/DEPLOYMENT.md` and `docs/DEPLOYMENT_DEV.md`. Every one of those provisions
a **native Python 3.14 bench running frappe `develop`**, which is the opposite of
what this line is for. Porting them unchanged would ship instructions that are
wrong on the bench this branch targets. They stay on `main`.

This branch is an application tree. Something else provisions the bench.

## Relationship to the other two HR apps

Three things named like HR can appear on a bERP bench, and they are not
interchangeable:

| App slot | What it is | Where it runs |
|---|---|---|
| `hrms` | upstream `frappe/hrms`, pinned at `version-16` in `bstBizEra/bERP`'s `scripts/apps/pins.json` | tenants, today |
| `hrms` | this repository's `version-16` branch: the same upstream release, with two title strings changed and `app_name` left as `hrms` | tenants, as a drop-in that needs no migration |
| `berp_hrms` (this branch) | bERP's fork of the same upstream release line, renamed | v16 benches — the development VM, and a tenant line if bERP moves to it |
| `berp_hrms` (`main`) | bERP's fork of upstream `develop` | the 17.0.0-dev development bench, CI only |

`hrms` and `berp_hrms` occupy different bench app slots, so a bench can hold
both — but **they ship the same doctypes**, so installing both on one *site*
collides on every one of them. Pick one per site.

Moving a tenant from `hrms` to this branch is not a fresh install: the site's
database still keys its state on `hrms`. That is what
[`RENAME_TO_BERP_HRMS.md`](RENAME_TO_BERP_HRMS.md#runbook-for-an-existing-site)
is for.

## Installing it on a v16 bench

On a native bench:

```bash
cd <bench>
bench get-app berp_hrms https://github.com/bstBizEra/bERP-HRMS --branch version-16
bench --site <site> install-app berp_hrms
bench build --app berp_hrms
```

`bench get-app` derives the app name from the directory basename, which is why
the name is given explicitly — the repository is `bERP-HRMS`, the app is
`berp_hrms`.

Check the bounds actually resolved rather than assuming they did:

```bash
bench --site <site> validate-dependencies
bench --site <site> list-apps
```

`bench validate-dependencies` **fails** on an unsatisfiable bound.
`bench get-app` only **warns**, so an app can install and then misbehave at
runtime. Run the validation; do not read a successful `get-app` as proof.

### On the bERP development VM

`berp-linux` runs a **Docker Compose** deployment
(`/srv/berp/deployments/dev/compose.json`), not a native bench. Containers there
are replaced on every `docker compose up`, so an app installed with `bench
get-app` inside a running container is lost the next time the stack restarts.

The supported route for Compose is to build a layered image that has the app
baked in, then install it into the site:

1. Add this branch to the `apps.json` used to build the custom image:

   ```json
   [
     { "url": "https://github.com/frappe/erpnext",       "branch": "version-16" },
     { "url": "https://github.com/bstBizEra/bERP-HRMS",  "branch": "version-16" }
   ]
   ```

   The repository directory must be checked out as `berp_hrms` for bench to
   name the app correctly.

2. Build the image with `frappe_docker`'s layered-image build, tag it, and point
   the stack's `custom_image` / `image` at it.

3. `bench --site <site> install-app berp_hrms`, then `bench build`.

**Verify before you start**, because none of it is confirmed from this
repository:

- The VM reported **2.4 GiB free** and no swap. An image build and an asset build
  both need more than that. Free space or add swap first — a `bench build` killed
  by the OOM killer leaves the site serving stale assets rather than failing
  loudly.
- The VM also runs four `mfi-r1-*` containers. Do not disturb them.
- Take a snapshot. This adds an app to a live deployment.

Nothing in this repository has been run against that VM. Treat the first attempt
as a test.

## Keeping it in step with upstream

```bash
git remote add upstream https://github.com/frappe/hrms.git   # one-time
git fetch upstream version-16
git merge upstream/version-16
```

That conflicts across the tree, because every file that names the package differs.
Resolving it means re-applying the substitution rule to the incoming side —
[`RENAME_TO_BERP_HRMS.md`](RENAME_TO_BERP_HRMS.md#the-substitution-rule) records
it exactly so a sync reproduces it rather than inventing one — and then re-running
`ruff` and `prettier` at the pinned versions.

`main` and this branch have **no shared bERP history**: each was cut from its own
upstream lane. A fix that belongs on both is applied to both, not merged between
them.
