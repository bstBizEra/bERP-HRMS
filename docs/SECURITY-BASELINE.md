# Security Baseline

## Policy

The imported upstream tree is bERP HRMS's **security baseline**. It tracks
`frappe/hrms` at commit `32a4d00976b85d65382674e41e4d9548780f4a3a` (develop lane,
17.0.0-dev).

- Static-analysis findings that exist in the imported upstream code are *inherited*. They
  are triaged on their own schedule and do not block bERP changes.
- Findings introduced by bERP's **own** changes block normally, and are fixed before merge.
- Upstream source is not modified to satisfy static analysis. Divergence on
  security-sensitive paths would conflict on every upstream sync and is a recurring cost
  paid for a one-time signal.

This mirrors the policy in `bstBizEra/bERP-CRM`, so both modules are triaged the same way.

## How the Semgrep gate behaves

`.github/workflows/linters.yml` runs `semgrep ci` against
[`frappe/semgrep-rules`](https://github.com/frappe/semgrep-rules), `r/python.lang.correctness`
and this repository's own `semgrep/test-correctness.yml`.

`semgrep ci` compares against the pull request's base branch and reports only findings in
files changed relative to it. Because the import is already on `main`, that works as the
policy intends:

- a pull request that does not touch a flagged file never re-reports its findings;
- a pull request that touches a flagged file but leaves the flagged line unchanged has that
  finding suppressed, because it is present in the baseline too;
- a pull request that introduces a *new* finding is blocked.

This is why `Linters` currently passes on pull requests: the inherited findings below are all
in unchanged upstream files, so none is reported. **A green Linters check does not mean the
tree is clean** — it means nothing new was added.

`.semgrepignore` excludes `hrms/patches/post_install/` from scanning. That is upstream's
setting and is unchanged here.

## Inherited findings

Enumerated by scanning `hrms/` with the Frappe rule set directly, rather than relying on the
pull-request-scoped CI view. **58 findings: 16 at ERROR severity, 42 at WARNING.**

| Rule | Count | Severity |
| --- | --- | --- |
| `frappe-enqueue-without-after-commit` | 11 | WARNING |
| `useless-get-doc-dict` | 10 | WARNING |
| **`security.frappe-ssti`** | **9** | **ERROR** |
| `frappe-cur-frm-usage` | 5 | WARNING |
| `security.guest-whitelisted-method` | 4 | WARNING |
| `frappe-print-function-in-doctypes` | 4 | WARNING |
| `frappe-single-value-type-safety` | 3 | ERROR |
| `security.relaxed-permissions` | 3 | WARNING |
| `use-vanilla-js-include` | 2 | WARNING |
| `frappe-breaks-multitenancy` | 2 | ERROR |
| `override-doctype-class` | 1 | ERROR |
| `frappe-no-functional-code` | 1 | WARNING |
| `security.frappe-sql-format-injection` | 1 | WARNING |
| `security.frappe-security-file-traversal` | 1 | WARNING |
| `frappe-modifying-but-not-comitting-other-method` | 1 | ERROR |

### The 18 security-rule findings

| Rule | Location |
| --- | --- |
| `security.frappe-ssti` | `hr/doctype/exit_interview/exit_interview.py:119` |
| `security.frappe-ssti` | `hr/doctype/interview/interview.py:279`, `:330` |
| `security.frappe-ssti` | `hr/doctype/leave_application/leave_application.py:724`, `:725`, `:750`, `:751` |
| `security.frappe-ssti` | `payroll/doctype/salary_slip/salary_slip.py:2264`, `:2265` |
| `security.guest-whitelisted-method` | `api/oauth.py:4`, `api/system_settings.py:4`, `utils/__init__.py:11`, `www/hrms.py:17` |
| `security.relaxed-permissions` | `hr/doctype/expense_claim/expense_claim.json:594`, `hr/doctype/leave_application/leave_application.json:290`, `hr/doctype/leave_ledger_entry/leave_ledger_entry.json:175` |
| `security.frappe-sql-format-injection` | `hr/doctype/interview/interview.py:429` |
| `security.frappe-security-file-traversal` | `overrides/company.py:94` |

All paths are relative to `hrms/`. Every one is unmodified upstream code that ships in
upstream releases.

## Triage priority

1. **`security.frappe-ssti` (9, ERROR)** — server-side template injection. The largest and
   highest-severity group, and unlike the advisory rules it names a concrete injection class.
   It touches payroll (`salary_slip`) and leave, which handle employee and salary data.
2. **`security.frappe-sql-format-injection` (1)** and **`security.frappe-security-file-traversal` (1)**
   — also concrete injection and traversal classes rather than review prompts.
3. **`security.guest-whitelisted-method` (4)** — endpoints reachable without authentication.
   `api/oauth.py` and `api/system_settings.py` warrant the closest look.
4. **`security.relaxed-permissions` (3)** — DocType permission definitions; check against the
   access model bERP actually wants.
5. **The remaining 40** — correctness and maintainability, not security.

This is a materially larger security surface than bERP CRM's, which reports 3 inherited
findings. HRMS handles payroll and personal employee data, so the gap matters more, not less.

## Not a security review

The counts above are a static-analysis inventory, not a verdict. No finding here has been
confirmed exploitable, and none has been confirmed safe. Frappe ships all of them, which is
evidence that upstream considers them acceptable in context — not evidence that they are
acceptable in bERP's deployment.

**This triage should complete before bERP HRMS is exposed to untrusted networks or holds
production employee or payroll data.** It does not block development or internal deployment.

Where hardening is needed, prefer fixing upstream and pulling the change back down, so bERP
does not diverge on security-sensitive paths.

## Reproducing this inventory

```sh
git clone --depth 1 https://github.com/frappe/semgrep-rules.git /tmp/frappe-semgrep-rules
semgrep scan --config /tmp/frappe-semgrep-rules/rules --metrics=off hrms/
```

## Review triggers

Re-run this triage when:

- upstream is merged and the diff touches a flagged file;
- a bERP change modifies a flagged file or adds a guest-accessible endpoint;
- the module is first exposed to untrusted networks or handles production data.
