# TemplateForge OCR third-party notices

TemplateForge bundles the Tesseract OCR executable and language data for offline Windows recognition.

- **Tesseract OCR**: Apache License 2.0. Source: https://github.com/tesseract-ocr/tesseract
- **tessdata_fast language models**: Apache License 2.0. Source: https://github.com/tesseract-ocr/tessdata_fast
- **Pinned language-data snapshot**: `87416418657359cb625c412a48b6e1d6d41c29bd`
- **Bundled languages**: English (`eng`), Hindi (`hin`), Bengali (`ben`), Assamese (`asm`), and orientation detection (`osd`).

The Windows release build downloads the language files from the pinned source snapshot and verifies each file against its Git blob SHA-1 before packaging. The corresponding Tesseract license file is copied beside the bundled runtime when supplied by the upstream installer.

OCR runs locally on the school's Windows PC. No uploaded page is sent to an AI/OCR web service. The original full-colour page is retained for printing; a temporary grayscale copy is used only for OCR.
