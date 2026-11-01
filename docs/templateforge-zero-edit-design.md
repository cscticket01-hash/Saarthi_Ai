# TemplateForge — school document template import

## Purpose

A school uploads its existing A4 receipt, marksheet, or payslip as a single-page PDF, PNG, or JPG. Vidya Saarthi keeps the original artwork as the page background, detects the fields and table, and overlays the current school's record data during the ordinary print-preview flow. Schools do not have to redraw the document or manually place every field.

## Implemented in draft PR #198 (not production-live)

- **Input and page safety:** single-page PDF, PNG and JPG/JPEG; portrait and landscape A4; EXIF orientation correction; high-resolution images are reduced to a 12 MP print-safe raster. Multi-page PDFs are rejected rather than silently truncating later pages.
- **Offline OCR:** the Windows release packages Tesseract 5.5.3 with pinned English, Hindi, Bengali, Assamese and OSD orientation data. OCR is local; no photo is sent to an external AI/OCR service. Original full-colour artwork is preserved; only a temporary grayscale copy is used for OCR.
- **Document understanding:** OCR-based receipt, marksheet and payslip type suggestion; multilingual label aliases; duplicate/overlapping field detection; confidence-gated field placement. A document-type mismatch or uncertain required field blocks publication.
- **Blank and populated tables:** recognizes fee/description/amount and subject/marks headers. It can infer up to twelve row slots from a blank table when a readable total-row boundary exists, or use readable sample rows. Current record values populate the detected slots; unused slots are masked so sample values do not leak into the new print. Extra verified record rows use separately labelled ISO A4 continuation sheets, never a fabricated extension of the scanned design. Excessive, missing or invalid data is rejected.
- **Print preflight:** validates missing values, text fit, receipt fee totals, marksheet subject totals and percentage, and payslip arithmetic before PDF rendering. Long text is fitted only while it remains legible; it is never silently truncated.
- **School Drive publication:** uploads the normalized page to that school's connected Drive, reads it back, and verifies its SHA-256. A school-scoped Firestore manifest stores the file identity, content hash, field map and engine version.
- **Version safety:** up to three template versions are retained per document kind. Uploading a new version does not replace the currently selected version. The new version appears in the existing template grid and the school explicitly chooses which version to use.
- **Real print routing:** the selected imported template is used by the receipt, marksheet and staff-payslip document render paths, not just by a standalone demo preview.

## Deliberate safety boundaries

- Clean bright A4 paper against a contrasting dark background can be normalized locally, including portrait and landscape. Borderless, glare-heavy or very steep photographs can still be rejected: a generic all-design perspective recovery claim is not validated.
- The table engine supports up to twelve detected row slots. It does not yet expand a table onto another page or invent additional rows when a school's record exceeds the uploaded table capacity.
- Only receipt, marksheet and payslip are supported by this importer. It does not replace student/teacher ID-card designers.
- A successful Drive image read-back does not by itself prove that the manifest has reached every other PC. End-to-end multi-PC propagation, offline/reconnect behaviour and rollback must pass the existing sync acceptance tests.
- Real school scan corpus comparisons, actual printer tests, and the full Windows installer test remain required.

## Release gate

PR #198 must pass the dedicated Windows TemplateForge workflow, the repository's platform/sync/security checks, and real A4 preview/print acceptance before merge or production deployment. No release is authorised by this design note alone.

## Live acceptance additions — not yet verified on physical schools

- **Poor scans:** the offline OCR pipeline has a one-time adaptive contrast retry for incomplete recognition. The preview still refuses old-person photos, ambiguous fields, conflicting first-pass geometry and low-confidence data. The temporary OCR raster is never the printed page.
- **Multi-page:** original A4 sheet remains page one, with up to eight separately labelled continuation sheets of up to 24 rows each. Original total and student identity are retained; no source artwork is copied into a fabricated second original. Incorrect totals and oversized rows still block publication.
- **Physical print proof:** the TemplateForge Windows review workflow publishes `templateforge-a4-print-proof` as an artifact. Print the PDF at 100% scale, measure the 100 mm vertical/horizontal black lines and their 10 mm margin from paper edges. Only real measurements can confirm hardware accuracy.
- **1/2/5-PC safety:** school-version readback checks that versions seen before the write remain present, and catches detectable lost updates. This is **not** atomic server CAS, nor proof of concurrent 5-device delivery or Drive rollback. Do not release until multi-PC real-cloud acceptance and rollback evidence exists.
- **Real school corpus:** do not upload identifiable student/staff records to the repository. Record redacted, consented A4 PDF/JPG/PNG, poor scan, signature, image and multi-row samples; compare against a paper proof and manually mark pass/fail. The synthetic unit tests do not satisfy this gate.


## Word and Excel import (draft PR #198)

- The SAME import button supports .docx/.doc from Word and .xlsx/.xls from Excel alongside PDF/JPG/PNG. This is a local format adapter, not another OCR, template editor or school sync engine.
- A locally installed LibreOffice desktop app converts the Word/Excel file to PDF without an online conversion service. On Windows, installed Microsoft Word or Excel desktop is a fallback with macros disabled and sources opened read-only. One of these desktop apps must be installed; browser-only Office does not supply a converter.
- The original Office bytes remain the immutable source-hash identity. Converted PDF pages pass the existing A4 validation, offline OCR, school isolation, field detection, preview and Drive read-back. Multi-sheet Excel or multi-page Word files are rejected rather than silently dropping school records.
- Office OpenXML ZIP metadata is checked for the expected document/workbook entries, archive expansion limits, and macro/external connections. Unsupported macro-enabled formats are rejected. Corrupt, oversized or encrypted files cannot activate a template.
- Automated tests check Word/Excel signature matching, spoofed ZIPs, original hash identity, A4 preview integration and multi-page safety. Live installed Word/Excel/LibreOffice and school documents still require physical acceptance.
