# Sync Engine 3.0 — Atomic Bundle Protocol: Phase 1

**Status: Draft / TEST-only. Do not enable production live authority or merge this PR before final release gates.**

## Baseline reuse / duplication check

- Reuse `cloudflare-sync/src/live-records.ts`: existing signed, school-scoped Durable Object, per-record optimistic CAS, immutable operation receipts, event journal, Drive backup queue and 24h verified-only retention.
- Reuse `cloudflare-sync/src/worker.ts`: same WebSocket wakeups, no second event stream.
- Reuse existing Windows local durable outbox, coalescing, person/card dependencies, photo compression and Google Apps Script storage owners. **No new queue, second engine, storage account or school migration.**
- The existing `managed_records_batch` path handles a bounded Google Script records batch but is **not** a verified atomic bundle of person data and staged media. Do not conflate these contracts.

## Implemented first milestone

- New internal **`live`** command `bundleCommit`: 2–5 distinct metadata records, one `bundleId`, immutable canonical manifest hash and exact replay. All records, Cloudflare live revisions, backup jobs and wakeup cursors are written under **one SQLite transaction**. One invalid revision, foreign-school record or duplicate operation rolls the whole batch back; never partly acknowledges.
- Reuses individual `commit` validation and the original `live_operations` identities, backup jobs and dependencies. `live_bundles` is **only a receipt journal** in the existing school Durable Object, **not** a new business-record store or queue.
- Safe collections only: `school_notices`, `school_calendar`, `school_settings` and `school_expenses` in the existing **opt-in TEST live authority**. Financial payment, person, documents and all media **fail closed** at this stage. This preserves their existing production owners while media proof is still missing.
- Restored the **85 KiB ID PDF** limit for all ID roles. Exact 85 KiB passes; 85 KiB+1 and 141.5 KiB fail closed without truncating source. The PDF can be generated with or without a photo, but no-photo UI hiding is **not yet implemented** in this phase.

## NOT implemented or claimed

- **No atomic Person + Photo + ID Card bundle yet.** The current photo/ID file lanes are distinct Durable Objects; their immutable SHA-256 receipts, size proofs and exact versions must be staged and verified before one *authoritative* person/card visible commit. A cross-DO transaction must never be falsely claimed.
- No changed existing Windows parent-then-document delivery ordering or Android/Web live activation. No new production Cloudflare routes, Apps Script upgrade or 85 KiB PDF re-compression guarantee. Uncompressible source stays retained and requires owner review, never silent downsampling or oversized success.
- No native production Windows/Android p95 2–5 s or 400-school/100,000-student certification.

## Required next phases and release gates

1. Introduce a **single school-scoped bundle owner** with a manifest of record revision, Photo (optional), strict 85 KiB ID PDF, exact staged file hashes and one operation ID. Verify all immutable staged file receipts before **one Ready transition**, not merely a 200 or Cloudflare admission reply.
2. Connect existing local outbox + idempotency (unsent Add/Edit coalescing and unsent Add/Delete cancellation only, preserve in-flight/financial histories) with this protocol; add crash/restart, conflict and exactly-once-visible tests.
3. Make peer Android/Windows/Web consume only Ready bundles; publish metadata and file references together; replay and Drive verification have independent statuses.
4. Independently verify real TEST Cloudflare ACK, real GS/Drive readback, 1/2/5-device visibility, photo/no-photo/oversize cases, Delete Everywhere including 24-hour retention, and p50/p95 per stage. Until successful, keep feature default-off.

## Contract invariants

- A 40 KiB portrait limit is **not** the total ID Card limit; the entire printable ID PDF including photo, QR, text, signature and logo must be ≤85 KiB.
- A no-photo ID PDF is generated and synced but its UI preview remains hidden (future presentation integration).
- Fee payments are immutable separate operations; never merge two payments into one logical payment.
- Cloudflare Accepted ≠ Drive Verified, and media failure ≠ successful record bundle.
- No cross-school authorization, replay or storage mixing.
