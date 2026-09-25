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

`.semgrepignore` excludes `berp_hrms/patches/post_install/` from scanning. That is upstream's
setting and is unchanged here.

## Inherited findings

Enumerated by scanning `berp_hrms/` with the Frappe rule set directly, rather than relying on the
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
| `security.guest-whitelisted-method` | `api/oauth.py:4`, `api/system_settings.py:4`, `utils/__init__.py:11`, `www/berp_hrms.py:17` |
| `security.relaxed-permissions` | `hr/doctype/expense_claim/expense_claim.json:594`, `hr/doctype/leave_application/leave_application.json:290`, `hr/doctype/leave_ledger_entry/leave_ledger_entry.json:175` |
| `security.frappe-sql-format-injection` | `hr/doctype/interview/interview.py:429` |
| `security.frappe-security-file-traversal` | `overrides/company.py:94` |

All paths are relative to `berp_hrms/`, which was `hrms/` until the app was renamed. Every
finding is in upstream code that ships in upstream releases; the rename rewrote identifiers
and import paths mechanically and changed no logic, so the triage below still holds.

## Triage verdicts — priorities 1 to 4

Worked against the imported tree (upstream `32a4d0097`). All 18 `security.*` findings have a
verdict below. Two carry an action for bERP's deployment, and two could not be settled from
this repository alone because the deciding behaviour lives in the Frappe framework rather
than in `berp_hrms/`. Those are marked **VERIFY ON A BENCH** and are the items worth doing first.

No security-relevant logic under `berp_hrms/` was modified. The app rename touched every
file, but only to rewrite the package name in import paths, asset URLs and dotted strings.
Where hardening is wanted it is proposed upstream or handled in bERP's own deployment, per
the policy above.

### Priority 1 — `security.frappe-ssti` (9, ERROR) — ACCEPTED

All nine are one construct: `frappe.render_template(<an Email Template field>, <a doc>.as_dict())`.

| Site | Template selected by |
| --- | --- |
| `hr/doctype/exit_interview/exit_interview.py:119` | HR Settings → `exit_questionnaire_notification_template` |
| `hr/doctype/interview/interview.py:279`, `:330` | Interview Reminder Settings |
| `hr/doctype/leave_application/leave_application.py:724`, `:725` | HR Settings → `leave_status_notification_template` |
| `hr/doctype/leave_application/leave_application.py:750`, `:751` | HR Settings → `leave_approval_notification_template` |
| `payroll/doctype/salary_slip/salary_slip.py:2264`, `:2265` | Payroll Settings → `email_template` |

Each pair is the subject and the body of a single template.

The template SOURCE is an `Email Template` record. The CONTEXT is document fields, which do
carry employee-entered text — but Jinja renders the template, not the context. A value
substituted into the output is not itself parsed as template syntax, so **an employee cannot
inject template code through a leave reason, an interview note or any other field.** That is
the question the issue asked, and it is the reason all nine are accepted.

What the rule does describe is a privilege escalation for anyone who can write an
`Email Template`, or repoint one of the Single settings above at a template they control:
Frappe's template environment exposes database read helpers, so such a user reads past their
own roles.

**Verdict: accepted.** Not employee-reachable. Keep `Email Template` write — and write on HR
Settings and Payroll Settings — on the operator role only, and treat edits to those records
as privileged changes rather than configuration.

### Priority 2 — injection and traversal (2)

**`security.frappe-sql-format-injection` — `hr/doctype/interview/interview.py:429` — ACCEPTED**

The whitelisted `get_events(start, end, filters)` f-string-interpolates `conditions`, which
comes from `frappe.desk.calendar.get_event_conditions` — Frappe's own helper for exactly this.
`start` and `end` are bound parameters (`%(start)s`, `%(end)s`). This is the standard Frappe
calendar pattern, used the same way across Frappe applications, and its safety is inherited
from that helper. Re-examine if Frappe changes `get_event_conditions`.

**`security.frappe-security-file-traversal` — `overrides/company.py:94` — ACCEPTED (low)**

`read_data_file()` is a bare `open()`. Both call sites build the path with
`frappe.get_app_path(...)`, and the second interpolates `frappe.scrub(country)`:

    frappe.get_app_path("berp_hrms", "regional", frappe.scrub(country), "data", "salary_components.json")

`scrub` lowercases and turns spaces and hyphens into underscores. It does **not** strip `/`
or `..`, so a `Country` record named with traversal characters would escape the app
directory. Three things keep this low: creating a `Country` record requires System Manager;
the target must parse as JSON; and `read_data_file` returns `"{}"` on `OSError`, so there is
no read-back channel — content only reaches `Salary Component` inserts.

**VERIFY ON A BENCH:** `scrub`'s behaviour is Frappe's, and Frappe is not vendored here.
Confirm it against the installed framework before relying on this reasoning.

A one-line upstream hardening — reject a scrubbed segment containing a path separator — is
worth proposing to `frappe/hrms`.

### Priority 3 — `security.guest-whitelisted-method` (4)

| Endpoint | Verdict |
| --- | --- |
| `api/oauth.py:4` `oauth_providers` | ACCEPTED |
| `api/system_settings.py:4` `get_user_pass_login_disabled` | ACCEPTED |
| `www/berp_hrms.py:17` `get_context_for_dev` | ACCEPTED **only while `developer_mode` is off** |
| `utils/__init__.py:11` `get_country` | **NEEDS HARDENING** |

`oauth_providers` returns name, provider name, authorize URL and icon for enabled Social
Login Keys. `client_secret` is fetched only as a presence test and is never returned. This is
the same surface Frappe's own login page exposes to anonymous visitors. It does enumerate
which providers are configured; that is accepted.

`get_user_pass_login_disabled` returns a single boolean the PWA login screen needs in order
to decide whether to draw the password form.

`get_context_for_dev` returns the full boot payload to an unauthenticated caller and is gated
by nothing except `frappe.conf.developer_mode`. Inert in a correctly configured production
site — which makes "correctly configured" a control bERP has to actually hold.

`get_country` is the one worth changing. It is unauthenticated, and for each unseen client IP
it makes an outbound request to `pro.ip-api.com` carrying `frappe.conf["ip-api-key"]`, then
stores the result in a module-level `country_info` dict. Three consequences, and the second
and third matter more to bERP than to upstream because bERP is multi-tenant by design:

- an unauthenticated caller with varied source addresses drives outbound requests and burns a
  paid API quota;
- the global dict grows without bound in a long-lived worker, one entry per distinct IP;
- the cache is per-process and not site-scoped, so entries are shared between sites on one
  bench.

### Priority 4 — `security.relaxed-permissions` (3)

**`hr/doctype/leave_application/leave_application.json:290` — NOT A FINDING**

The block is `{"permlevel": 1, "read": 1, "role": "All"}`, which reads alarmingly. The only
permlevel-1 field on Leave Application is `status`. A permlevel grant is a field-level filter
layered on top of document permissions and confers no document access of its own, so this
lets an authenticated user see `status` on leave applications they can **already** read —
which is what lets an Employee see the state of their own request. Working as intended.

**`hr/doctype/expense_claim/expense_claim.json:594` — BY DESIGN**

Expense Approver at permlevel 1. The only permlevel-1 field on Expense Claim is
`approval_status` — precisely the field an approver exists to set. The same file's
`role: All` permlevel-1 read resolves the same way as Leave Application's.

**`hr/doctype/leave_ledger_entry/leave_ledger_entry.json:175` — VERIFY ON A BENCH**

The block grants `role: All` with `if_owner: 1` and `create`, `write`, `delete`, `submit`,
`read`, `report`, `export`, `share`, `email`, `print`. Leave Ledger Entry holds leave
**balances**. Read literally, that lets a user create and submit ledger entries they own.

The mitigation is `"in_create": 1` on the doctype — Frappe's marker for "only ever created by
another document". `cancel` and `amend` are absent from the grant, and `write`/`delete` reach
only drafts, which the normal flow never leaves behind. So the grant is almost certainly
inert.

"Almost certainly" is not good enough for the records that decide leave balances, and the
enforcement is Frappe's, not this repository's. **Confirm on a bench that an account holding
only the Employee role cannot create or submit a Leave Ledger Entry** — through the REST API
as well as the Desk UI. If `in_create` does not block it, an employee can mint their own
leave balance, and that is blocking.

### Actions this triage produces

| # | Action | Owner |
| --- | --- | --- |
| 1 | Confirm a plain Employee cannot create or submit a Leave Ledger Entry (API and Desk) | bench check, before production data |
| 2 | Confirm `frappe.scrub` does not strip path separators, then judge the traversal accordingly | bench check |
| 3 | ~~Assert `developer_mode` is off on every tenant, in the deploy path rather than by convention~~ — **done**, `scripts/deploy-production.sh` | bERP deployment |
| 4 | ~~Leave `ip-api-key` unset, and rate-limit or block `/api/method/berp_hrms.utils.get_country` at the edge~~ — **done**, blocked at nginx and asserted unset | bERP deployment |
| 5 | Propose upstream: reject path separators in the scrubbed country segment | upstream `frappe/hrms` |
| 6 | Propose upstream: bound and site-scope the `get_country` cache | upstream `frappe/hrms` |

Actions 1 and 2 are verification, not change, and neither needs an upstream decision.

Actions 3 and 4 are done. `scripts/deploy-production.sh` now blocks
`/api/method/berp_hrms.utils.get_country` in the generated nginx config — validated with
`nginx -t` and rolled back if it will not parse — and, after the hardening step,
re-reads the config frappe will actually see and stops the deploy if `developer_mode`
is on or an `ip-api-key` is set.

Blocking that route costs nothing: no shipped frontend calls it. `hooks.py` registers
`get_country` as a **Jinja method**, and Jinja runs inside the template engine without
touching `/api/method/`. If a tenant ever adds client code that needs the route, turn
the block into a rate limit rather than deleting it.

## What this triage does not claim

The nine SSTI findings and the two injection findings are accepted on **reasoning about the
code**, not on attempted exploitation. Nothing here was fuzzed, and no proof-of-concept was
written. An accepted verdict means "the described attack does not reach this code by the path
the rule implies", not "this code is proven safe".

Two verdicts rest on Frappe framework behaviour that cannot be read from this repository and
are marked accordingly. Until those two bench checks are done, treat priority 4 as open.

**The gate still stands: complete the two bench checks before bERP HRMS holds production
employee or payroll data.** The rest of the triage does not block development or internal
deployment.

Where hardening is needed, prefer fixing upstream and pulling the change back down, so bERP
does not diverge on security-sensitive paths.

## Reproducing this inventory

```sh
git clone --depth 1 https://github.com/frappe/semgrep-rules.git /tmp/frappe-semgrep-rules
semgrep scan --config /tmp/frappe-semgrep-rules/rules --metrics=off berp_hrms/
```

## Review triggers

Re-run this triage when:

- upstream is merged and the diff touches a flagged file;
- a bERP change modifies a flagged file or adds a guest-accessible endpoint;
- the module is first exposed to untrusted networks or handles production data;
- Frappe changes `scrub`, `get_event_conditions`, or how `in_create` is enforced — three
  verdicts above rest on framework behaviour rather than on anything in this repository.
