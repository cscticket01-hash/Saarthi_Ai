# Fees Collection — saved payment and on-demand receipt

Fees Collection continues to use the existing Windows screen, local student stream, school-scoped fee ledger, payment history, and existing Sync Engine. This change updates the current owner; it does not introduce a second fee module or a new synchronizer.

## Payment save contract

- **Collect Payment** saves only the fee payment record and its matching monthly ledger record in the existing durable local batch.
- Payment Save does not render a PDF, compress a PDF, create a receipt document, enqueue a receipt upload, open a print dialog, or fetch an older receipt PDF.
- Partial installments retain the same month ledger, fee identity, fee heads, and original fee amounts. A stale balance or ambiguous student generation fails closed instead of creating another ledger.
- Fee settings retain per-head Monthly, Annual, and One-time billing. Legacy fee heads default to Monthly. One-time admission month is tied to the immutable student generation; the server rejects attempts to move or clear an already recorded admission month. Annual rollover selection still depends on the Windows school setting and needs cross-PC consistency verification.

## Receipt preview and user actions

- **Preview Receipt** reads the saved payment fields and displays the receipt record only. Preview does not render, download, or fetch PDF bytes.
- **Print Receipt** is the explicit action that prepares or retrieves the receipt bytes and opens the existing Windows print dialog.
- **Download PDF** is the explicit action that prepares or retrieves the receipt bytes and saves the PDF locally.
- The new payment stores the selected receipt template identifier, not generated PDF bytes. Existing historical PDF-backed receipts remain supported; their bytes are fetched only after Print or Download is pressed.

## Sync and financial safety

- The payment and ledger remain in their existing school-scoped collections and existing Cloudflare/Drive sync ownership. Drive backup is not part of the Save button's foreground work.
- Cloudflare's student lifecycle policy validates that feeAdmissionMonth and feeAdmissionPersonId are paired, correctly formatted, bound to mobileStableId, and immutable for that generation. Fee payment and ledger records also carry a fee-frequency snapshot; a One-time fee is rejected by Cloudflare unless its month and person generation match the locked student admission record.
- The codebase still needs a production record-only atomic Cloudflare transaction for the payment+ledger pair before cross-PC simultaneous collection can be claimed as verified. The existing PDF-backed atomic coordinator is TEST-only and is not used for this no-PDF Save path.
- Refund, cancellation, and credit-note behavior is intentionally not inferred. It requires the school's approved accounting policy; existing collected payments are not silently rewritten.

## Validation status

- No GitHub Actions workflow, CI run, build, or test command was started for this update, as requested.
- Source and regression-test changes are committed for later validation. They have not been executed in this turn.
- Real two-PC payment acceptance, authenticated Cloudflare-to-Drive completion, and native printer acceptance remain unverified until separately authorized validation is performed.
