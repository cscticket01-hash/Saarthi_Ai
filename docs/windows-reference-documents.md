# Windows reference documents

Windows uses four teacher ID front/back designs (green angular, gold/teal, cyan landscape and navy/red), four report card designs (blue semester, cyan quarterly, yellow quarterly and burgundy academic), and one school receipt. Source references were visually inspected and redrawn in vector code. No sample identity, photo, signature, barcode or watermark is embedded.

The shared Android renderer remains unchanged. Existing student ID designs remain unchanged. Windows no longer offers the old document layouts or the old teacher/receipt fallback. Stored records and older Drive PDFs are not deleted.

School template choices remain school-scoped. Old default/out-of-range selections map to the first new design; receipt choices all map to the single supplied design. Preview, print and download share one renderer. Actual school branding, teacher data and photos, student result marks and fee-payment fields populate documents. Missing GPA/credit/term/behavior information is shown as unavailable rather than invented. Long subject/fee lists continue on numbered pages. Original aspect ratio is retained and may be fitted by a printer to A4.

Receipt amounts distinguish expected amount, total paid, this installment and remaining balance. New centrally connected Windows report saves upload the selected PDF into the active school's own Drive and persist its reference inside the existing isolated school result path. PDF bytes are not saved into Firestore result documents. Offline marks remain available for preview without pretending they reached Drive.

Verification: render all nine designs with photo/logo/signature, read PDFs with an independent parser to check fields, clipped final rows, receipt installment amounts and all 25 continuation subjects/items, visually inspect every front/back and report/receipt page, and complete native Windows compilation before publishing. Test fixtures contain clearly separate sample records; real school documents use stored data.
