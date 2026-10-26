# Sync Engine 3 unified upgrade — authoritative continuation

## Exact repository state
- Repository: `cscticket01-hash/Saarthi_Ai`.
- Branch: `feature/sync3-unified-repair-20261026`.
- PR: https://github.com/cscticket01-hash/Saarthi_Ai/pull/135 — OPEN, DRAFT; do not merge or release.
- Latest implementation commit: `19c6c489788252886dcd6c431b27a67d7b54a683`.
- Baseline/main verified unchanged: `9c1cacd6cef905490e5249cc0958ae686dc4e68f`.
- A subsequent documentation-only checkpoint may contain this file. Read current PR head before editing; never overwrite another session's changes.

One existing Sync Engine 3 is the only queue/recovery authority. The removed standalone guardian must not be recreated. No separate repair scheduler, paid AI API, queue reset or school migration was added.

## Implemented and tested milestones
1. Starting branch `283eeab79ccfeb7a3fcc22fcc554b3856da0c53f`: record-scoped diagnostic timeout/5xx isolation and notification watchdog; all seven original workflows verified successful before continuation.
2. `c1cfa1b4a2a851186739525fd87377cd3a5179e5`: existing owner gets a 40-second read-only diagnosis deadline, persistent five-attempt automatic budget per operation, exhausted-budget escalation and journal identity guards. Explicit Sync Now may admit another bounded diagnosis but preserves attempt history and exact pending requests. Late readback never acknowledges anything. Media retries classify protected errors, retain review blocks and school-wide authorization/configuration/quota gates across restart/inventory refresh. Broker detects interior/tail hint gaps and malformed metadata. Windows rejects backwards/non-reset epoch/empty advancing cursors before durable persistence and restarts on same-profile school change.
3. `24057a1a9d261de24d6ff414880757e71e691dee`: corrected CI fixtures, without weakening assertions: compare reconstructed Timestamp values, not object identity; use consistent package imports for typed media exceptions. Initial CI had 36 PASS / 11 FAIL for these fixture errors; corrected runs passed.
4. `189a0fcd8997853d0641e1958558e0c65a8b9fd1`: existing `prepareManagedBatch` uses a durable school/profile-specific 2–10 record window. Failed/partial or >=8s requests halve it; complete <=2s responses grow by one. Existing 250KB bound, capability gate, parent/delete ordering, frozen request IDs and individual receipts remain authoritative. Control Center shows actual broker-request timing, observation time, next window and successful receipt counts; it does not claim downstream device apply latency.
5. `b8d57f0df580b80269649baf781f3b7296997050`: negotiated durable metadata replay pages in the existing Firestore hint owner, atomically with the legacy hot window. <=64 hints/page; <=32 retained pages/school/epoch; <=64 events per response and at most two page reads/request. Up to 2048 recent hints are retained (oldest partial page can reduce effective history). Old clients/brokers use the existing broad reconciliation fallback. Missing/foreign/corrupt/expired pages and old-publisher gaps never become fake ACKs or inferred deletions. Windows requests replay using its existing durable inbox and independent applied progress.
6. `19c6c489788252886dcd6c431b27a67d7b54a683`: atomic replay fault fixture models rollback and enforces Firestore reads-before-writes. Injected page-write interruption leaves the original hint head unchanged; exact retry advances once. Legacy transaction adapters without delete retain the original bounded hot window. Android dashboard quota deadline/attempt state persists in the existing school/person-bound secure cache. Duplicate notifications/resume/restart cannot bypass provider cooldown or fabricate a new verified dashboard timestamp. Existing recovery timer remains the owner; no claim of execution while the OS stops the app.

## Modified files
- Owner/recovery: `lib/windows_pending_school_sync.dart`, `lib/windows_sync_engine.dart`, `lib/sync_recovery_policy.dart`.
- Transport/media/monitor: `lib/windows_firebase_sync.dart`, `lib/windows_binary_downloads.dart`, `lib/windows_remote_change_feed.dart`, `lib/windows_sync_control_center.dart`.
- Android: `lib/mobile/school_session.dart`.
- Broker: `functions/school-change-feed.js`, `functions/managed-schools.js`.
- Tests: `functions/test/school-change-feed.test.js`, `test/windows_sync_intelligent_repair_test.dart`, `test/windows_binary_downloads_test.dart`, `test/windows_remote_change_feed_test.dart`, `test/sync_recovery_policy_test.dart`, `test/mobile_smart_sync_test.dart`.
- Review workflow: `.github/workflows/sync3-unified-repair-review.yml`.

## Exact verification on implementation commit 19c6c489
- Full backend: **547/547 PASS** locally and in CI. OAuth broker/download suite: **19/19 PASS** in platform backend job.
- Four exact-source jobs: **74 tests PASS per job**, Windows JSON, Windows SQLite, Linux JSON, Linux SQLite. Push run https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261008175 and PR run https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261012520 both SUCCESS.
- Analyzer has zero errors. Ten existing warnings/info were reported under the repository's existing non-fatal warning/info policy (unnecessary imports/type checks/non-null assertions); no checks were disabled to hide failures.
- JSON school storage SUCCESS: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261012629.
- Document conflict / student Sheet SUCCESS: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261012631.
- Sheet recovery / student lifecycle SUCCESS: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261012610.
- Duplicate Save / safe replacement SUCCESS: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261012527.
- Standalone Self-Healing removal SUCCESS: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261012525.
- Multi-PC review: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261012554. SUCCESS on Windows and Linux: each job passed 12 correctness tests, 2 load tests and 102 retained queue/scheduler regressions.
- Platform review: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40261012518. SUCCESS: backend, school-security, Android unsigned preview, Web build, Windows compile, real OS SQLite crash recovery and fresh-start/restart smoke checks all completed successfully. Private isolated-test-cloud job SKIPPED by existing branch gate; not real-cloud acceptance.
- `git diff --check` and Node syntax checks PASS. No local Flutter SDK; Flutter evidence comes from exact-source GitHub Actions, not a fabricated local test run.

## Synthetic measurements — never present as real provider/device speed
- 15,000 notification commits, five reconnect schedules: 17,384 exact catch-ups, 136 broad gap reconciliations, ~5818ms in one local in-memory Firestore simulation. At most 33 retained head/page documents. This measures metadata only.
- Negotiated replay: 1000 hints caught up in 16 bounded responses/client after broker restart, tested with 1, 2 and 5 independent cursors; legacy reset, expiry, missing/foreign/truncated pages tested.
- Linux two independent SQLite caches plus actual Apps Script source in a synthetic VM: 1000 students upload/ACK 7.611s, verified apply 0.667s; 5000 students upload/ACK 119.489s, verified apply 2.740s. 12 correctness, 2 load and 102 retained regression tests passed in that job. Not physical PCs or cloud latency.
- Windows two-SQLite-PC synthetic VM: 1000 students upload/ACK 15.955s, verified apply 1.028s; 5000 students upload/ACK 166.260s, verified apply 7.868s. Runner/fixture measurements, not physical networking.
- Existing fsync-backed attendance queue component, mocked remote ACK: 15,000 submitted/completed, zero data loss, zero final pending, 1000 duplicate submissions prevented, total 3.185s, enqueue durable-accept p95 97.56ms. This is not Google/Firebase acknowledgement latency or a measured improvement over a baseline. Existing 1k/5k/10k/25k/50k component cases also passed.
- No measured real-world speedup, Android applied latency, device availability or provider quota headroom is claimed.

## Preserved safety and compatibility
Strict school/profile/device authorization; 1–5 Windows PC policy; offline storage; durable queues; original operation IDs/times/revisions; exact frozen retry wire data; no-op saves; immediate changed-record dispatch and hourly idle reconciliation; no fake ACK; no pending deletion without verified owner acknowledgement; no blind newer-cloud overwrite; same-field review; protected financial event IDs; student deletion generations and recycle retention; exact media hashes and previous verified file fallback.

A received hint cursor is not an applied record/ACK cursor. Replay emits hints only; authenticated authoritative point reads/deltas remain mandatory. Explicit tombstones govern deletions. Missing local/cloud rows are not proof of deletion or permission to resurrect data. Actual true conflicts, auth, unknown identity, unverified content and quota constraints are never silently bypassed.

Current Apps Script baseline remains `2026-10-25.2`; this continuation did not modify the Script source or deploy any school project. Batch capability negotiation and old transport fallbacks remain. Preserve existing school IDs, Drive roots, Script properties/secrets and `/exec` URLs. The independently deployed production-used broker branch was previously at `533c49d0a9abb9abf67fc05894e3ba9d42549490`; do not assume this PR is deployed there.

Replay adds a page write alongside the existing hint-head write and an expired-page delete on rotation, within existing Firestore. Provider quotas/contention/retention behavior require isolated real-cloud acceptance before rollout. No extra service was provisioned.

## Remaining work in execution order — unfinished engineering, not claimed blocked by permissions
1. Refresh final CI on the exact current PR source; diagnose failures before new changes. Keep draft.
2. Design and implement bounded external Google Sheet edits/readable-projection auditing against existing authoritative revision/payload proofs, including metadata bypass and deleted-row protection. Do not treat a missing point read as a delete or automatically import unverified external edits. Current derived readable fields are not an authorized write API.
3. Extend the existing owner's allowlisted repair playbooks/postconditions and tests for cache corruption/rebuild, missing-ACK evidence, notification delivery and media recovery. Distinguish diagnosis, retry admission and verified repair. Do not create another engine, scheduler or queue writer.
4. Provider-capable resumable transfer journals/offsets/chunk integrity with feature negotiation and duplicate-safe full-transfer fallback. Current verified complete-file retry is **not** resumable upload/download; originals must remain untouched.
5. Android/Web applied-state convergence and durable page checkpoint/resume, broader persistent retry limits/background lifecycle ownership and OS constraints. Existing quota improvement is not full background sync implementation.
6. Measure changed-record priority, batch pressure and end-to-end Save → broker → durable Script ACK → Android/Web apply, with truthful p50/p95/p99 and quota evidence; keep the existing parent/file/delete dependency rules.
7. Expand full-record 15k acceptance (current 15k tests are notifications/queue components); injected disconnects/restart/401/403/409/429/502/503/timeouts, 24h recycle boundary, school isolation and media interruption across all relevant owners.
8. Real two/five physical Windows PCs plus Android/Web, isolated signed cloud/Drive/Sheets quota tests and existing-school `.2` compatibility acceptance. Physical devices/private school credentials were not accessed. Do not claim their pending rows are cleared.

## Final checkpoint
All eight unique review workflows (plus duplicate exact-source push review) completed SUCCESS on implementation commit `19c6c489788252886dcd6c431b27a67d7b54a683`. This documentation-only checkpoint changes no runtime/test/workflow code; subsequent CI on the documentation head is separate. PR remains DRAFT and full-mission release acceptance is still incomplete. Final tree was compared with the GitHub implementation before checkpointing; unrelated older worktrees were preserved.

## Exact next implementation step
After current CI finishes, start item 2 with `VS_managedDelta`, `VS_sheetItem`, `VS_recordHead`, `VS_sheetDecode`, `VS_seedRecordHeads`, existing recovery routes and `functions/test/helpers/managed-storage.js`. Read existing rules first. Design a bounded read-only audit/report before any automatic mutation; account for interrupted writer/head updates and deliberate tombstones, so an external edit is not confused with safe lost-ACK replay. Add synthetic VM fixtures and compatibility tests, then regenerate the Script bundle through the existing builder only if source changes. New capabilities must be optional; no existing private deployment change is authorized.

## Release gates
Not release-ready for the complete A–J mission. Engineering and physical/cloud acceptance above remain. No main merge, Windows/Android release, website publication, production Render deployment, private Apps Script modification or real-school writes were performed or are authorized by the current request. Complete independent development and maintain this handoff after every milestone; never ask for secrets in chat.
