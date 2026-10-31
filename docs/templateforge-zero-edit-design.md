# TemplateForge — zero-edit image/PDF import

## Requested behavior
An authenticated school operator uploads a **portrait A4 PDF / JPG / PNG** inside **Fee Receipt**, **Report Card** or **Staff Payslip**. The desired destination is a normal reusable, school-scoped template: select once, generate from the actual school record, show print preview, then print/PDF. **No drag-and-drop, manual coordinates or text edits.**

## Implemented in draft PR #198
- One import and renderer engine shared by all three destinations, bounded input validation (size, source magic, raster dimension), school identity checks and immutable versioned local drafts.
- Screen's visible Upload action invokes zero-edit OCR/automatic field detection, not the earlier manual editor.
- Local-only Tesseract OCR adapter (TSV word bounding boxes) with 25-second timeout, temp-file cleanup and no external AI API.
- Conservative label/position mapper with confidence threshold, multiple-label ambiguity detection, original background preservation, narrow masking of recognized sample values and A4 PDF sample preview.
- Saved-draft preview reopening from each of the three tabs, without editing.
- Test fixtures for three document kinds, invalid/foreign file rejection, automatic label locations, ambiguous fields and no false claims of grades or money values.

## NOT implemented or safe to activate yet
- **Tesseract is not bundled by this PR.** The installed Windows app must have an approved, reviewed local OCR binary and English language pack available on PATH. Otherwise the app displays a clear OCR-unavailable error and does not alter current selected templates. Installer packaging, integrity/signature check and redistribution licence review remain required.
- Arbitrary A4 scans are **not** perfectly convertible. Perspective/skew correction, unsupported languages, missing data labels, photo regions and multi-page PDF are out of scope; page 1 only.
- Complex repeated **fee-item rows, subject-wise grades/marks and pay component tables** are *not* reconstructed automatically. The converter detects labels but deliberately keeps outputs **local drafts**. It never guesses financial values or student grades and never says the template is ready for school-wide print.
- Existing native selectable document templates are untouched. **Imported drafts are not yet added to school-wide active template selection or 2–5-PC sync**, because their original background files must first be delivered through the existing authenticated school Drive document outbox with verified ACK, versioning, rollback and school isolation. Do not write large image blobs into ordinary Firestore school settings.
- No Cloudflare/Firebase infrastructure change, no Apps Script overwrite, no licence change and no automatic production release.

## Required next acceptance gates
1. Package an approved offline OCR runtime with Windows installer and check 10+ A4 samples of each template type, including scans and image-based PDFs.
2. Build repeatable table/row layout reconstruction and record-schema mapping for all 3 types; validate amounts, totals and grades against the source record.
3. Add a verified preview/print comparison and fail closed on unreadable fields, duplicate names or mismatched sum.
4. Integrate school-owned asset sync and versioned template approvals using existing safe Drive storage. Prove 1/2/5-PC restart/offline and rollback acceptance.
5. Only after all above: make approved imported templates appear beside built-in selections and route all receipt/report-card/payslip print functions through the common chosen renderer.

Keep PR #198 **DRAFT / NOT LIVE** until complete and tested. No manual mapping should be required from school users.
