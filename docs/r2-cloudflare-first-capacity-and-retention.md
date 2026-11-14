# Private Cloudflare R2 staging: TEST design and release gates

## Required client-to-cloud behavior
Windows and Android persist original operations in their existing durable local outboxes. A reopened client retries unchanged identity; a closed/offline device cannot send a previously unsent record. For new TEST record/file paths, the Worker stages bytes in private R2 under a global quota actor, then the existing Cloudflare Durable Object accepts; the app may display Cloudflare accepted / Google backup pending without waiting for Google Drive.

The existing Cloudflare Worker alarm and signed Render/Apps Script owner complete Google delivery asynchronously, independently of whether the app is still open. A Cloudflare ACK is NEVER a Google Drive completion ACK.

After an exact original signed Google completion, private R2 bytes remain available at least 24 hours from first accepted staging; only then can the R2 actor delete them. Pending, failed, unverified, foreign or mismatched original receipts cannot trigger deletion at 24 hours or afterward. The original identity and receipt are retained.

## Decimal GB admission barriers
- School data ceiling: 8,000,000,000 bytes, across all schools in this dedicated TEST R2 bucket.
- System reserve: 2,000,000,000 bytes, inaccessible to normal school writes.
- Combined modeled limit: 10,000,000,000 bytes; atomic global Durable Object quota admissions prevent concurrent oversubscription by this Worker.
- Same immutable staged object replay is not charged against the admission ledger twice. Reservations count even if R2 is temporarily unavailable; this fails closed rather than oversubscribing.
- A genuine full-budget response is HTTP 507 R2_CAPACITY_EXCEEDED. Both client retry policies preserve local originals and do not advertise cloud ACK.

## Important limits and costs
Cloudflare R2 provides 10 GB-month per month of Standard storage free allowance, NOT an absolute free account cap. R2 Class A and Class B operations and other Cloudflare products have separate quotas/costs. Ledger estimates only bytes written through this private Worker bucket; external writes and other buckets can bypass it. Do not enable public uploads or additional bucket writer credentials, and monitor actual R2 billing.

The TEST bucket is saarthi-sync-r2-test (private, Standard, APAC). Never set a blanket 24h R2 lifecycle deletion rule: that would discard unverified delayed Google backups. Verified-only cleanup is controlled by the owner.

## Existing owners preserved
- cloudflare-sync/src/spool.ts: original record/file operation identity, durable claims and Google-completed states
- cloudflare-sync/src/live-records.ts: native live, 24h verified-only cache and CAS
- functions/cloudflare-delivery.js: Cloudflare-owned async Google Drive uploader and original receipt validation
- functions/live-sync-reconciliation.js: historical marker proof fence; never synthetic settlements
- lib/sync_recovery_policy.dart: local operations retained on capacity and network failures

## Release hold
This PR is TEST-only initial private-R2 staging for school record + file lanes. It does NOT yet cover all notices, attendance, mobile or atomic live bundles, physical Windows/Android offline/restart, 2–5 second latency, or production rollout. Issue #279 has 14 historical unverified markers (7 missing original jobs, 7 conflicting original payload hashes). No new stage or R2 object is proof those historical operations were backed up. Do not merge migration PR #282 or deploy this R2 staging to production from CI alone.

## Required verification before activation
1. Worker type-check and full Miniflare R2 replay/409/507/fail-closed tests PASS.
2. Match exact TEST worker build SHA to private TEST bucket binding, run school-bound synthetic R2 put/replay and inspect ledger.
3. Prove 24h verified-only deletion with Google signed ACK, app closed and failed Google variants; demonstrate original pending bytes never delete.
4. Extend all remaining data lanes and signed app quota display while preserving existing local outbox semantics.
5. Recover every historical release marker with its original proof; pass real Windows/Android plus Google Drive delivery and 2–5 second Cloudflare ACK-to-Idle gates.
6. Only then allocate separate production private bucket and reviewed production R2 bindings, deploy production Worker/broker, and release signed app updates.
