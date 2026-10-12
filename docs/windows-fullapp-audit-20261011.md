# Windows application audit — 11 October 2026

Baseline inspected: PR #26 source `2cc37e9b3567027c10b6a7ab27eae030e8c31374`, with latest ID/QR reports and master resume checkpoint. This is an implementation review, not independent release acceptance or physical-device verification. Existing successful CI was not repeated locally.

## Confirmed defects corrected in this unit

- Salary payment retries previously treated any existing payment ID as success, even if the amount, payment date, method or reference differed. Exact retries remain idempotent; conflicting reuse now fails without changing the original payment, balance or history. Malformed stored payment history requires review.
- Analytics previously preferred a name/profile fingerprint over immutable student IDs. Two different students sharing a name and class could count as one, while an edited duplicate with the same immutable ID could count twice. Analytics now uses exact, case-preserving immutable identity, then source document identity. Unknown identity is never inferred from matching names. No student records are modified or removed.
- Analytics had no bound school origin or asynchronous load generation. A late refresh could overwrite a newer year selection, or show earlier-school metrics after a school change. Reads, commit and rendering now validate the original school profile; only the current load generation can update state. Unavailable reads fail visibly instead of becoming fabricated zero metrics.

Focused regression source: `test/windows_financial_analytics_regression_test.dart`. Runtime execution and analyzer are **UNVERIFIED** in this environment because Flutter/Dart is unavailable. `git diff --check` passed. No performance timings are claimed.

## Existing implementation and remaining acceptance

| Area | Source observations | Remaining verification |
|---|---|---|
| Startup/licensing | Global managed-school gate wraps routes; startup selects tenant cache before setup, then App Lock and local dashboard | Original PC offline startup, licence expiry, restart and restored-school routing |
| Skip | Legacy licence widget still has Skip; current centrally managed flow uses mandatory account/authorization gate | New assignment mentions Skip but older approved mandatory-login requirement conflicts; security was preserved |
| Student/teacher | Existing directory, creation/edit/photo, unique identity, academic-session/promotion modules remain | Actual offline CRUD/restart, multi-PC readback, photo quality and foreign-school denial |
| Fees/receipts | Existing fee collection, session fee structures, transaction history and print/export code remain | Real refunds/corrections workflow not found in inspected fee modules; retention/reversal policy requires a concrete specification and review |
| Expenses/salary | Existing local expense bridge and exact-paise salary/payment flows remain; payroll replay corrected | Physical offline/reconnect, concurrent PCs, printed payroll/receipt acceptance |
| Analytics | Six collection reads run concurrently; expense and exam sources are local. Identity and origin/generation defects corrected | Runtime/month-selection regressions; pass/fail cards still count exam result records and can include multiple exams for one pupil—authoritative final-result policy remains necessary |
| Notices | Current publish method saves locally and schedules background sync; it does not wait for delivery or falsely claim notification ACK | Original-school operation/ACK trace, actual Android notice flow and precise pending/conflict presentation |
| Documents/printing | Existing upload, PDF and document template modules remain; this unit does not change designer/QR reader ownership | Representative real photos, seal/signature/PDF readability, physical printer alignment |
| Performance | Analytics already batches six reads; central startup profile resolution uses saved identity. No large architectural rewrite | Actual startup/admin/local-save/CPU/memory measurements at approved TEST sizes; no synthetic estimate is substituted |

Additional scoped expense fixes now bind page reads/actions to the original profile and School ID, reject late loads, and hide earlier-school results after switching. Each add dialog creates a secure UUID and original timestamp before submission. Retries reuse the exact original payload; changed details after an uncertain submission require review rather than overwriting or creating a duplicate. Non-finite amounts are rejected. Legacy expense IDs remain readable. Focused intent and widget regressions were added; execution remains UNVERIFIED locally. No original-school pending operation, fee, attendance, document, QR identity, licence rule or production deployment was changed.
