# Security Baseline — `version-16`

## Policy

The imported upstream tree is this line's **security baseline**. It tracks
`frappe/hrms` at commit `7e0fba4bf11a63ac7b21a717610e235310815c1a`
(`version-16`, 16.19.0).

- Static-analysis findings that exist in the imported upstream code are *inherited*. They
  are triaged on their own schedule and do not block bERP changes.
- Findings introduced by bERP's **own** changes block normally, and are fixed before merge.
- Upstream source is not modified to satisfy static analysis. Divergence on
  security-sensitive paths would conflict on every upstream sync and is a recurring cost
  paid for a one-time signal.

This is the same policy the `main` line carries, and the same one
`bstBizEra/bERP-CRM` uses.

### What the rename did and did not change

Measured on this tree, with the [Frappe rule set](https://github.com/frappe/semgrep-rules)
at the whole repository rather than just the application package:

| Tree | Findings |
|---|---|
| Upstream `7e0fba4bf`, unmodified | 87 |
| This branch | 85 |

The two that disappeared are the two annotated below. **No finding was
introduced.** Four `frappe-enqueue-without-after-commit` findings in
`payroll_entry.py` moved by two lines, because re-running the repository's own
`ruff` after the rename rewrapped an import block above them; the code is
unchanged.

### The two `# nosemgrep` annotations

| File | Rule | Verdict |
|---|---|---|
| `berp_hrms/hooks.py` | `override-doctype-class` | Upstream's design, unchanged here |
| `berp_hrms/api/oauth.py` | `security.guest-whitelisted-method` | Accepted — see the triage referenced below |

They are the only ones, and they were added deliberately rather than as a shortcut past a
red check. The app rename (`hrms` → `berp_hrms`, see
[RENAME_TO_BERP_HRMS.md](RENAME_TO_BERP_HRMS.md)) rewrote the dotted paths inside
`override_doctype_class` and the route `oauth_providers` passes to
`get_oauth2_authorize_url`. `semgrep ci` fingerprints a finding by its *matched text*, so
changing that text makes an inherited finding read as a new one — permanently, for these
two, on every pull request that touches either file.

The no-modification rule exists because divergence "would conflict on every upstream sync".
The rename already guarantees that for every file in the tree, so the reason the rule was
written for no longer distinguishes these two lines. Both findings already had a written
verdict; the annotations cite it rather than replacing it.

This is not a precedent for silencing a finding that has no verdict. A new finding still
blocks, and an inherited one with no triage entry still gets triaged rather than annotated.

## How the Semgrep gate behaves

`.github/workflows/linters.yml` runs `semgrep ci` against the Frappe rules,
`r/python.lang.correctness` and this repository's own `semgrep/test-correctness.yml`,
**on pull requests only**. `semgrep ci` compares against the pull request's base branch
and reports only findings in files changed relative to it. So:

- a pull request that does not touch a flagged file never re-reports its findings;
- a pull request that touches a flagged file but leaves the flagged line unchanged has that
  finding suppressed, because it is present in the baseline too;
- a pull request that introduces a *new* finding is blocked.

**A green `Frappe Linter` check does not mean the tree is clean** — it means nothing new was
added. Note also that a push to this branch with no pull request open runs no linter at all.

`.semgrepignore` excludes `berp_hrms/patches/post_install/` from scanning. That is upstream's
setting and is unchanged here.

## Inherited findings

Scanning `berp_hrms/` alone, the way the `main` line's inventory was taken, and counting the
two annotated findings back in: **86 findings — 17 at ERROR severity, 69 at WARNING.**

| Rule | Count | Severity |
| --- | --- | --- |
| `useless-get-doc-dict` | 37 | WARNING |
| `frappe-enqueue-without-after-commit` | 11 | WARNING |
| **`security.frappe-ssti`** | **9** | **ERROR** |
| `frappe-cur-frm-usage` | 5 | WARNING |
| `security.guest-whitelisted-method` | 4 | WARNING |
| `frappe-print-function-in-doctypes` | 4 | WARNING |
| `frappe-breaks-multitenancy` | 3 | ERROR |
| `frappe-single-value-type-safety` | 3 | ERROR |
| `security.relaxed-permissions` | 3 | WARNING |
| `use-vanilla-js-include` | 2 | WARNING |
| `override-doctype-class` | 1 | ERROR |
| `frappe-modifying-but-not-comitting-other-method` | 1 | ERROR |
| `frappe-no-functional-code` | 1 | WARNING |
| `security.frappe-sql-format-injection` | 1 | WARNING |
| `security.frappe-security-file-traversal` | 1 | WARNING |

### The 18 security-rule findings

| Rule | Location |
| --- | --- |
| `security.frappe-ssti` | `hr/doctype/exit_interview/exit_interview.py:88` |
| `security.frappe-ssti` | `hr/doctype/interview/interview.py:279`, `:330` |
| `security.frappe-ssti` | `hr/doctype/leave_application/leave_application.py:697`, `:698`, `:723`, `:724` |
| `security.frappe-ssti` | `payroll/doctype/salary_slip/salary_slip.py:2176`, `:2177` |
| `security.guest-whitelisted-method` | `api/oauth.py:10`, `api/system_settings.py:4`, `utils/__init__.py:11`, `www/berp_hrms.py:17` |
| `security.relaxed-permissions` | `hr/doctype/expense_claim/expense_claim.json:594`, `hr/doctype/leave_application/leave_application.json:290`, `hr/doctype/leave_ledger_entry/leave_ledger_entry.json:175` |
| `security.frappe-sql-format-injection` | `hr/doctype/interview/interview.py:429` |
| `security.frappe-security-file-traversal` | `overrides/company.py:94` |

All paths are relative to `berp_hrms/`, which was `hrms/` until the app was renamed.

## Triage

This is the **same set of 18** — same rules, same endpoints, same doctypes, same
constructs — that the `main` line carries. Only the line numbers differ, because
`version-16` and `develop` are different snapshots of the same upstream files.

The verdicts therefore transfer, and they are not duplicated here: read
[`docs/SECURITY-BASELINE.md` on `main`](https://github.com/bstBizEra/bERP-HRMS/blob/main/docs/SECURITY-BASELINE.md#triage-verdicts--priorities-1-to-4)
for the reasoning on each one. In summary:

| Priority | Finding | Verdict |
|---|---|---|
| 1 | `frappe-ssti` × 9 | ACCEPTED — template source is an `Email Template` record; employee-entered text is context, not template syntax |
| 2 | `frappe-sql-format-injection` | ACCEPTED — Frappe's own `get_event_conditions` calendar pattern |
| 2 | `frappe-security-file-traversal` | ACCEPTED (low) — **VERIFY ON A BENCH** that `frappe.scrub` does not pass path separators |
| 3 | `guest-whitelisted-method` × 4 | `oauth_providers`, `get_user_pass_login_disabled` ACCEPTED; `get_context_for_dev` accepted **only while `developer_mode` is off**; `get_country` **NEEDS HARDENING** |
| 4 | `relaxed-permissions` × 3 | Two are permlevel-1 field grants working as intended; `leave_ledger_entry.json:175` is **VERIFY ON A BENCH** |

### Two deployment actions are NOT satisfied on this branch

The `main` line closes two of its triage actions inside
`scripts/deploy-production.sh` — asserting `developer_mode` is off, and blocking
`/api/method/berp_hrms.utils.get_country` at nginx.

**This branch ships no deployment scripts.** It is an application tree meant to be
installed into a bench that something else provisions, which on the bERP
development VM is a Docker Compose stack. So both controls are open here and are
the responsibility of whatever deploys this app:

1. `developer_mode` must be `0` on any site holding real data.
2. `/api/method/berp_hrms.utils.get_country` should be rate-limited or blocked at
   the edge, and `ip-api-key` left unset. No shipped frontend calls that route —
   `hooks.py` registers `get_country` as a Jinja method, which does not go through
   `/api/method/`.

Plus the two bench checks the triage leaves open:

3. Confirm a plain Employee cannot create or submit a `Leave Ledger Entry`, through
   the REST API as well as the Desk UI.
4. Confirm `frappe.scrub` does not strip path separators, and judge the traversal
   finding accordingly.

**The gate stands: complete 1–4 before this app holds production employee or payroll
data.** None of them blocks development or an internal deployment.

## Reproducing this inventory

```sh
git clone --depth 1 https://github.com/frappe/semgrep-rules.git /tmp/frappe-semgrep-rules
semgrep scan --config /tmp/frappe-semgrep-rules/rules --metrics=off berp_hrms/
```

Add `--no-exclude` equivalents at your own discretion; the counts above were taken with
semgrep 1.178.0 and the rule set as of 2026-09-25.

## Review triggers

Re-run this triage when:

- upstream `version-16` is merged and the diff touches a flagged file;
- a bERP change modifies a flagged file or adds a guest-accessible endpoint;
- this line is first exposed to untrusted networks or handles production data;
- Frappe changes `scrub`, `get_event_conditions`, or how `in_create` is enforced.
