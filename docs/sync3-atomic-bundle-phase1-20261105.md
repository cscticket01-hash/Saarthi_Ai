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

## Phase 2: signed media staging preflight (TEST-only, not a publish)

- Reuses the **same existing** school-scoped Cloudflare file Durable Object lane. Added read-only `bundleProof` that verifies the original persisted one-chunk bytes, exact SHA-256, completed staging, original school/upload identity, and nonexpired availability. This is not a new upload owner or background queue.
- In the existing live Durable Object worker, `bundlePrepare` checks exactly one ID PDF (complete `%PDF-` envelope/EOF and **up to 85 KiB**) plus at most one optional portrait (**up to 40 KiB**). Each immutable file proof must match `uploadKey`, expected school-scoped ID, content SHA-256, size and MIME. Reject missing/receiving/GC-expired bytes, altered manifests, cross-school IDs, duplicate kinds, oversized PDFs and photo-only requests.
- The existing authenticated/licensed managed-school broker exposes `managed/live/bundle-preflight` behind the already opt-in `liveProtocol: 1` school gate. It is **read-only** and only reports `mediaReady`; it does not mutate a Student/Teacher record, publish to any PC, return a Drive file ID or claim an Atomic Bundle ACK.
- Added Cloudflare Miniflare proof tests for exact 85 KiB, no-photo, optional 40 KiB photo, corrupted hash, unsupported/oversized file, replay and **no partial visibility**. Added broker school-scope/licence/invalid-request regressions. CI evidence belongs to the final PR head only.
- **Next required development:** bind a proof to an immutable person+document manifest with a single visible commit *and* a verified file/Drive backup dependency; then integrate the Windows durable outbox and Android/Web receiver. In particular, never pass the current media preflight result off as a committed Student Bundle. No fake 2–5 s acceptance or 1 lakh attendance claim.

## Phase 3: archived Person + ID document atomic publish (TEST-only implementation)

- New `bundlePublish` request reaches the **existing school live Durable Object**, not a second sync engine, queue or file owner. The broker rejects it unless the licensed school has explicit isolated-test confirmation and both native `students_directory` / `teachers_directory` and `documents` migration markers active.
- Recheck each file with the original school-scoped file Durable Object and require a **verified Drive upload receipt** before publish. The complete original staged bytes must still match SHA-256; ID PDF must be <=85 KiB and the optional portrait <=40 KiB. JPEG/PNG/WebP media signatures are also checked. An upload ACK alone is not an archive ACK.
- Once verified, person and its bound `documents` record are committed under **one SQLite transaction**, with a single `bundleId`, exact person generation, immutable Drive file IDs/hashes and durable replay receipt. Any second-record CAS failure rolls back the person, owners, events and backup job. Receivers cannot see the parent record without the document event.
- The document is written with server-attested `bundleMedia`, `bundleManifestHash` and ID-card `fileId`. A client-supplied conflicting file ID or forged media reference is rejected. The existing Drive record backup queue remains independently pending until verified by Script readback; `cloudState: committed` does **not** mean the person record itself has been saved in Drive.
- An unchanged replay uses the stored bundle receipt; mutated operation or media manifests are rejected. Proof stays within existing school security/retention isolation. Added worker and broker tests for preflight, malformed image, Drive receipt, transaction rollback, replay and school/migration gates.

**Important limitation:** This Phase 3 path is **archive-first** (wait for file Drive receipt before publishing). That is safe, but does **not** satisfy the requested 2–5 second Cloudflare-first delivery. It also does not yet connect the Windows durable person/card outbox, Android/Web receivers, no-photo preview hiding, one-operation universal Receipt/Marksheet path, real 1/2/5 physical PCs or production GS/Drive p95 tests. Do not claim those gates PASS and **do not merge/deploy** this Draft PR merely on worker CI PASS. The next protocol needs immediate durable Cloudflare-byte availability to authorized receivers, with independently verified Drive promotion and no premature deletion.

## Phase 4: replay and Windows crash/restart group boundaries (TEST-only)

- Cloudflare SQLite events now keep `bundle_id`, `bundle_size` and `bundle_index` within the existing school Durable Object journal. This is a non-destructive migration of existing event history.
- `changes` emits complete 2–5 record bundles even at the 100-event and 300-KiB page limits. A request to resume from the middle of a bundle fails closed (409); a verified snapshot is required.
- No-op or duplicate individual commits cannot be packaged as a successful group, and a person-generation replacement with unbounded cascade tombstones is refused by this bounded atomic path.
- Windows replay parser checks exact group completeness, order and identity before durable cursor advancement. The existing local inbox retains those group markers through restart and will not reconcile a partial group when a local 100-event batch would split it.
- New worker and Dart regressions cover byte-boundary split, partial/mid-bundle cursor, metadata tamper, legacy compatibility and local durable batching/lost-event fail-closed behavior.
- **Not yet achieved:** atomic Windows business-data apply (the reconciler must validate the whole group in one local transaction), Android/Web receiver migration, Windows outbound bundle publish, Cloudflare-first prearchive delivery, real Drive readback/p95 and physical 1/2/5-PC certification. This draft still must not be merged/deployed.
