# Local fee collection and receipt preview

Fees Collection paints its shell immediately and uses the existing local student/ledger streams. It no longer starts a twelve-class settings preload or waits for a UID-config spinner. Only the selected class is loaded; collection remains disabled until its local ledger and UID configuration are available. A month change retires the earlier month's ledger snapshot.

Transaction History subscribes to the same school-scoped `fee_payments` collection that the existing Sync Engine updates. Opening History never waits for an Apps Script list call. Manual refresh schedules the existing engine without hiding the current list.

Collect Payment commits the original PDF, payment, ledger and pending receipt upload in one durable local batch. It displays `Payment collected`; WhatsApp remains an explicit optional button. A serialized local read guard rejects a changed balance before any batch records or queue entries are written. Same-ID retries retain the original; changed retries and stale balances require review. An original receipt hash protects the retained PDF during preview and upload.

The new flow does not directly create a cloud payment and then overwrite it with a second local generation. Payment records and PDF documents retain their separate existing operation IDs, revision/ACK owners and retries. The document outbox publishes the exact original PDF through the existing versioned document protocol. `receiptDocumentId` connects the immutable payment to its receipt; no local filesystem path or PDF base64 is placed in the synced payment record. Legacy `save_fee_payment` callers also strip PDF base64 before writing a record.

The collection panel retains the most recent receipt action for the selected student. Changing students or search clears that action. The durable history remains. Both collection and history open an in-app PDF preview, with printing through the native system print settings; no Drive URL/browser navigation is used. Older payments without a receipt-document reference are rendered from their saved payment fields and may use the currently selected legacy receipt template. New payments always use their original PDF.

No Apps Script contract change is needed by this patch. Existing financial conflicts are retained: a screenshot cannot establish which version is correct. The existing authenticated point-read/review owner must verify those records; no payment is overwritten, acknowledged or discarded based solely on a matching receipt number.

## Validation status

- Local Dart parser/format validation and `git diff --check` completed.
- Added regression coverage for offline atomic payment/PDF/outbox saves, identical and changed retries, partial payments, stale balances, retained original bytes, school isolation, profile reopen, invalid PDF/nonfinite amounts, guarded batch rejection, separate verified document completion and local history rendering.
- Added the new suite to existing Linux/Windows platform review steps, including SQLite runs.
- Flutter execution on this workstation was blocked by automatic security review after the SDK setup attempted an unrelated cloud metadata request. No bypass was attempted. The user subsequently explicitly authorized repository publishing and release. Hosted test results and exact release identity are tracked in PR #171; initial payment/PDF/ledger owner tests passed, and the widget harness advances both filesystem I/O and its fake clock.
- Native Windows printer UI, two-PC receipt visibility and the existing real-school conflict still need their respective device/authenticated verification. No production release or live-school data change was performed.
