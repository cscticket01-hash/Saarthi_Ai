# Draft sync development and coordinated TEST acceptance

Existing protocol 2, Windows outbox, attendance queue, compression and organized migration are extended, not replaced. No service runs after the Windows process terminates; this draft does not install an OS background service. Minimized Windows retains its existing timers. A running client and attendance worker reconcile every four minutes; committed local edits retain the 250 ms coalesced automatic trigger and bounded exponential retry. Cloud data reads do not require Windows presence. Updated Scripts negotiate one protocol-2 batch delta for a Windows pull instead of 21 sequential collection requests; older Scripts retain the existing per-collection fallback.

## Read-path limits

The central broker caches signed, verified dashboard and website responses for at most five seconds. Keys include school and complete request hashes (including mobile session/checkpoints); session expiry bounds dashboard cache expiry. Payloads are copied before returning, limited to 512 KB each and 32 MB/1,000 entries total. Failed/foreign responses cannot bypass signed identity validation. Record writes, logout, block and acknowledged attendance invalidate views; attendance ACKs also emit existing FCM hints. FCM failure does not invalidate a durable attendance ACK.

This is an in-process acceleration cache, not a durable authoritative data mirror. Cold cache misses still need Apps Script. Direct owner Script edits are visible after cache expiry. It does not prove a 24/7 availability SLA or eliminate Google API quota/cold-start limits. Existing school policy caches retain their 30-second bound. No Firebase polling or record mirror is added by this cache.

## Compression

Normal images target 80 KB with the existing quality floor, minimum dimensions, orientation/paper processing and lossless comparison. Originals and high-quality generations remain retained. PDFs use 80 KB per page as a target and keep their source PDF; readable multi-page output may exceed the target. The preview reports original/output sizes and percentage saved; negative savings remain visible. Existing PDF raster limits are 20 pages / 40 megapixels. Compression tests include valid decode, source preservation, truncated input, alpha, quality floor, QR and content checks; they are not a real school document readability sign-off.

## TEST-school migration

Use an existing isolated school explicitly labelled TEST. Install generated bundle 2026-10-08.2 into its own Script deployment, preserving its school ID, root, secret and /exec URL. Do not install it in real schools during this review.

First run `VS_previewOrganizedStorageMigration()`: read-only counts, canonical hashes, target partitions, binary inventory and limits, with zero writes. Then run begin and repeated bounded step calls. Capture preview and completed status, validate all 25 source collections/17 books and binary IDs/URLs, make one test edit, and exercise rollback with that edit retained. Resolve review-role tabs without guessing. Preserve backups and all queue records.

## One coordinated device round

1. Record build commit, TEST school ID, Windows/Android versions, network, Render instance status and UTC clock offsets. Use two Windows profiles/PCs and one Android TEST install. Confirm every client belongs to this same test school; retain another school's denial check.
2. For a student, teacher, fee collection, exam result, attendance, notice, document and profile mutation: save locally, capture operation ID/revision, local save time, enqueue time, upload start, durable cloud ACK, pending count before/after and visible Android/Web revision/time. Repeat enough times for p50/p95; do not report one sample as a percentile.
3. Minimize Windows and repeat. Stop Windows only after ACK and check Android/Web cloud reads. Queue an offline edit, restart, restore connectivity, verify same operation ID and exactly one remote mutation. Never clear the queue.
4. Edit concurrently on the second PC: verify conflict preservation, no older response overwrites newer local changes, and explicit tombstones do not resurrect records. Restore PDFs/photos on PC 2 and Android, verify MIME, bytes/revision, visible QR/text/signature and preserved source.
5. For attendance load, prepare at least 1,000 TEST-only student identities/sessions and submit through the live staging HTTP API, recording accepted durable enqueue separately from final Drive ACK. Verify 1,000 unique final results within ten minutes, duplicate retries and queue counts. Existing fsync load artifacts use mocked Drive ACKs and cannot satisfy this live test.
6. Measure physical scanner throughput separately; record scanner/device/staff conditions. Capture FCM foreground, background, notification tap and resume behavior; do not assume sleeping Android stays running.
7. Capture Firebase monitoring reads/writes/storage/quota from authorized monitoring, and backend versus Script versus Drive-upload durations separately. Windows diagnostics provide bounded 256-sample p50/p95 for measured local notice saves, queue wait and record ACKs; absent metrics remain unmeasured. No guaranteed 20 ms cloud latency or quota guarantee.

Real-account prerequisites: isolated TEST-school owner Script/Drive access, school login, test Android QR sessions and the two PCs. Credentials stay in the app or authorized account flow. No chat password/PAT is requested. Real-school migration requires separate explicit approval.

## Live attendance runner (prepared, not executed)

`.github/scripts/staging_attendance_acceptance.mjs` is opt-in and pinned to the existing staging URL. Run locally with `--run-isolated-test`, VS_TEST_SCHOOL_ID, VS_TEST_ISOLATED_CONFIRM set to that same ID, VS_TEST_ADMIN_ID_TOKEN from authorized app login, VS_TEST_ATTENDANCE_FIXTURES pointing to a private local JSON, and VS_TEST_REPORT_PATH. Never commit the token/session fixture or paste it in chat.

Fixture shape: `{schoolId, isolatedTestSchool: true, requests: [...]}` with exactly 1,000 distinct TEST identities. Each request contains an existing authorized TEST sessionToken, role, personId, linkToken, correct location/accuracy and entry/exit mode. The runner verifies the authenticated school registration name starts with TEST before submission. It refreshes attendance permits, uses four workers, distinguishes durable enqueue from final ACK, and polls only same-school queue statuses in batches of 25 with a 10,000-read ceiling. It changes only explicitly opted-in TEST attendance and retains every accepted operation on failure. Check authorized project quota before opting in; this runner does not enable billing or manufacture test accounts.

Reports distinguish HTTP enqueue p50/p95, backend queue-created-to-completed p50/p95, polling-observed completion since run start, pending counts and the ten-minute objective. A completed queue state is backed by the existing worker's verified Script ACK, but physical scan rate and Drive/device visibility still need the coordinated round.
