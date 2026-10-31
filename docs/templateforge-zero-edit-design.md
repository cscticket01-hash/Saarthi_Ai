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


## TemplateForge 3 draft improvements (NOT LIVE)
- Recognises common receipt/marksheet/payslip labels in English, Hindi, Bengali and Assamese when corresponding offline Tesseract packs are installed. Recognition never calls cloud AI. Existing school artwork stays full colour; a temporary grayscale copy goes to OCR.
- Handles EXIF-oriented mobile pictures and rotates a sideways A4 photo to portrait. Strong perspective distortion, severe skew, illegible handwriting and arbitrary non-A4 photos are not promised.
- Suggests document kind by evidence; rejects mismatched receipt/report-card/payslip uploads without overwriting school selections.
- Detects up to eight OCR-verified repeated fee/subject row slots when both table headers and number cells are readable. Values come from the actual record feeItems/marks, not scanned sample amounts. A different row count blocks print instead of silently losing data.
- Preview checks missing fields, excessive length, text auto-fit limits, receipt fee sum and payroll arithmetic before rendering. It fails closed on unsafe data rather than clipping text or guessing numbers.
- Adds targeted regression tests for multilingual OCR, wrong kind, non-A4 input, sideways camera photos, row-count mismatch, invalid salary, fee totals and fitted text.

**Still blocking production:** validated print comparison corpus on real school scans, photo/logo/signature/QR slot inference, multilingual OCR runtime installer bundling/integrity/licence review, richer variable-length table reflow, authenticated school Drive asset sync with verified ACK/rollback, multi-PC propagation, approval/selection and actual receipt/marksheet/payslip print route integration. The new checks do not imply arbitrary photos are correctly converted; unreadable or unmatched documents must be rejected. No existing school record or active template is modified by this draft.

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
