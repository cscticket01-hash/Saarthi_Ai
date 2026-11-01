# TemplateForge — school document template import

## Purpose

A school uploads its existing A4 receipt, marksheet, or payslip as a single-page PDF, PNG, or JPG. Vidya Saarthi keeps the original artwork as the page background, detects the fields and table, and overlays the current school's record data during the ordinary print-preview flow. Schools do not have to redraw the document or manually place every field.

## Implemented in draft PR #198 (not production-live)

- **Input and page safety:** single-page PDF, PNG and JPG/JPEG; portrait and landscape A4; EXIF orientation correction; high-resolution images are reduced to a 12 MP print-safe raster. Multi-page PDFs are rejected rather than silently truncating later pages.
- **Offline OCR:** the Windows release packages Tesseract 5.5.3 with pinned English, Hindi, Bengali, Assamese and OSD orientation data. OCR is local; no photo is sent to an external AI/OCR service. Original full-colour artwork is preserved; only a temporary grayscale copy is used for OCR.
- **Document understanding:** OCR-based receipt, marksheet and payslip type suggestion; multilingual label aliases; duplicate/overlapping field detection; confidence-gated field placement. A document-type mismatch or uncertain required field blocks publication.
- **Blank and populated tables:** recognizes fee/description/amount and subject/marks headers. It can infer up to eight row slots from a blank table when a readable total-row boundary exists, or use readable sample rows. Current record values populate the detected slots; unused slots are masked so sample values do not leak into the new print. More rows than the scanned table can safely hold are rejected.
- **Print preflight:** validates missing values, text fit, receipt fee totals, marksheet subject totals and percentage, and payslip arithmetic before PDF rendering. Long text is fitted only while it remains legible; it is never silently truncated.
- **School Drive publication:** uploads the normalized page to that school's connected Drive, reads it back, and verifies its SHA-256. A school-scoped Firestore manifest stores the file identity, content hash, field map and engine version.
- **Version safety:** up to three template versions are retained per document kind. Uploading a new version does not replace the currently selected version. The new version appears in the existing template grid and the school explicitly chooses which version to use.
- **Real print routing:** the selected imported template is used by the receipt, marksheet and staff-payslip document render paths, not just by a standalone demo preview.

## Deliberate safety boundaries

- A photo must still show a clean, near-A4 page. Automatic perspective/edge crop for a page photographed at a strong angle is not implemented; ambiguous or non-A4 pages are rejected rather than guessed.
- The table engine supports up to eight detected row slots. It does not yet expand a table onto another page or invent additional rows when a school's record exceeds the uploaded table capacity.
- Only receipt, marksheet and payslip are supported by this importer. It does not replace student/teacher ID-card designers.
- A successful Drive image read-back does not by itself prove that the manifest has reached every other PC. End-to-end multi-PC propagation, offline/reconnect behaviour and rollback must pass the existing sync acceptance tests.
- Real school scan corpus comparisons, actual printer tests, and the full Windows installer test remain required.

## Release gate

PR #198 must pass the dedicated Windows TemplateForge workflow, the repository's platform/sync/security checks, and real A4 preview/print acceptance before merge or production deployment. No release is authorised by this design note alone.
