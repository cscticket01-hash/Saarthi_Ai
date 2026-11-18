# 2026-11-18 Windows ID preview and 130.8 KB PDF — triage (NOT FIXED)

## Evidence received
- Windows School Admin Console screenshot: student search shows an existing student, but the bottom snackbar says `ID card preview unavailable: Bad state: School record changed. Refresh first.`.
- User reports a 130.8 KB PDF; **no original PDF bytes were attached** (the supplied attachment was a screenshot). Do not call this a tested 130.8 KB fixture.
- Do not deploy or merge this investigation automatically.

## Exact source trace (main branch at time of review)
1. `lib/windows_school_identity.dart`: `WindowsSchoolIdentity.ensure(collection,id)` fetches the local record and throws `School record changed. Refresh first.` when the resolved `doc(id)` is null. It does **not** mean PDF compression failed.
2. `lib/id_card_engine.dart`: `IdCardEngine._render` optimizes decorative card backgrounds, preserves vector QR/text, uses conditional font retry and compact-media retry, then calls `SchoolMediaBudgets.verifyGeneratedPdf('idCard', output)`.
3. `lib/school_media_budgets.dart`: a generated card must be <= 85 * 1024 bytes. A 130.8 KB PDF is over this limit; rejection is intentional and must not be bypassed.
4. `test/school_media_budgets_test.dart` already covers strict 85 KiB boundaries and oversized synthetic PDFs. These synthetic tests are NOT real-world PDF compression proofs.

## Required reproduction and fix before this can be marked ready
- Obtain the original 130.8 KB PDF file (not a screenshot) and its source photo/template/font data. Record true byte length, PDF validity, page count/geometry, text and QR preservation, print readability, before/after sizes and safe failure mode. Do not alter or truncate original bytes.
- Reproduce ID-preview failure in Windows with a record shown by search while `WindowsSchoolIdentity.ensure` receives the selected record ID. Capture profile/school IDs, collection and canonical document ID using privacy-safe assertions/logging without exposing tokens, student names or phone numbers.
- Identify the dashboard's call site and verify that search results and ID issuance both use the same canonical document ID and *active* school profile; refresh stale selection on mutations and make a single safe retry only after matching identity. Do not invent a missing record or bypass cross-school/deleted checks.
- Add regression tests for stale display ID, deleted/renamed record, profile switch during preview and successful preview with stable ID. Include a real PDF fixture test only after source bytes are supplied.
- Run Flutter tests on the exact branch and Windows UI/device acceptance. Only then remove draft status.

## External reference reviewed
- `DavBfr/dart_pdf` / `printing` already has a working Flutter `PdfPreview` API. This can inform preview presentation, but it does not fix the local record-ID mismatch or allow an oversized generated ID PDF to be accepted.
