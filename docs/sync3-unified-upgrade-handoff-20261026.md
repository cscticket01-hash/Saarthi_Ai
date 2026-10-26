# Sync Engine 3 — unified intelligent repair continuation (2026-10-26)

## Scope and exact source
Repository: `cscticket01-hash/Saarthi_Ai`. This work starts from main `9c1cacd6cef905490e5249cc0958ae686dc4e68f` (merged PR #134). Branch: `feature/sync3-unified-repair-20261026`. Read the latest HEAD/PR and CI before editing; this file is a handoff checkpoint, not proof of subsequent runtime acceptance.

**One existing Sync Engine 3 is the only authority.** The standalone 1000-error guardian was intentionally removed (PR #51); do not recreate `lib/health`, an autonomous competing scheduler, or independent queue writer. All repair actions use the existing serialized CAS/outbox owner and signed school-scoped readback.

## Implemented in this branch
1. `lib/windows_pending_school_sync.dart`: isolate transient record-specific diagnostic timeout/5xx, retaining journal cooldown, operation ID, queue bytes, revisions and local edits. Only independent eligible operations may proceed, at most five bounded probes per run. Shared network failure halts further probes. Authorization, quota, configuration, identity and unknown errors still propagate fail-closed. A deferred probe is *not* a successful repair.
2. `lib/windows_remote_change_feed.dart`: bound the notification long poll with a 45-second read timeout (normal broker long poll is 20 seconds); retry the same received cursor on failure and leave hourly fallback available. Read timeout never ACKs or applies.
3. Regression cases in `test/windows_sync_intelligent_repair_test.dart` and `test/windows_remote_change_feed_test.dart`: independent per-record timeout, shared disconnection stop, preserved local edits and original identities, durable cooldown, idle stalled listener and late-result suppression.
4. Targeted CI on the branch validates Dart source and JSON/SQLite modes. **Do not mark tests PASS unless an exact-commit run completed successfully.**

## Continuation milestone — bounded repair, media safety and notification integrity
Starting head verified from GitHub: `283eeab79ccfeb7a3fcc22fcc554b3856da0c53f`; PR #135 OPEN/DRAFT; main remains `9c1cacd6cef905490e5249cc0958ae686dc4e68f`. All seven primary workflows on the starting head completed SUCCESS (runs 40229211359, 40229211340, 40229211339, 40229211283, 40229211218, 40229211301, 40229211304).

Implemented in this milestone, pending exact-commit Flutter CI:
- Existing record owner: 40-second probe deadline, five lifetime automatic diagnosis attempts per operation persisted in the existing journal, exhausted-budget escalation, identity validation. Explicit Sync Now can request another bounded diagnosis without resetting history, changing requests, granting ACKs or bypassing access/quota/conflict checks.
- Existing media cache: classified permission/configuration/conflict/validation failures persist review blocks; school-wide access/configuration blocks and quota cooldown persist across restarts and inventory version changes. Administrative retry cannot skip quota cooldown. Temporary 502/503 and interrupted download retries still require exact byte hash/version/readback; original files remain untouched. No provider resumable protocol is invented.
- Broker hint projection: detect missing interior events, missing tails and malformed IDs/collections; require broad reconciliation instead of silently advancing past gaps. Corrupt sequence/epoch rejects visibly and releases listeners. Invalid empty record IDs become broad hints.
- Windows listener: reject backwards/non-reset epoch/empty advanced cursors before durable cursor writes; restart on school change even if profile scope is unchanged.
- Four-way existing repair CI now covers binary-download regression tests too.

Local evidence: backend full suite **542/542 PASS** after using already installed Firebase dependencies (initial run failed only because firebase-admin was absent in the clean worktree; rerun passed). Focused change-feed **11/11 PASS**. Synthetic in-memory Firestore listener run: 15,000 commits, 5 simulated clients, 17,384 exact catch-ups, 136 broad gap reconciliations, 5,522ms in one local run; this is not provider throughput or physical acceptance. `git diff --check` PASS. No local Flutter SDK found; do not label Flutter tests PASS until GitHub Actions finishes on the new commit.

Modified sources: `lib/windows_pending_school_sync.dart`, `lib/windows_sync_engine.dart`, `lib/windows_binary_downloads.dart`, `lib/windows_remote_change_feed.dart`, `functions/school-change-feed.js`; corresponding regression tests; `.github/workflows/sync3-unified-repair-review.yml`.

Next precise step: inspect exact new-commit CI; fix every failure. Then continue phase B durable partitioned event retention, phase C measured adaptive transport / provider media / bounded Sheets external-edit audits, and phase D mobile/web and physical acceptance. The current 64-event feed intentionally retains broad fallback; durable partitioned replay is **not implemented** by this milestone. No production merge/release/deploy or private school changes are authorized.

### CI correction after c1cfa1b4
Exact-commit Linux jobs on run 40259335853 reported 36 PASS / 11 FAIL, all in newly added assertions/fixtures: six queue comparisons used object identity for reconstructed Timestamp values; five media fixtures mixed package and file import URIs, creating distinct exception class identities. Corrected tests to compare full durable queue values including timestamp milliseconds and to import the typed exception through the same package URI as the media source. No queue fields or security assertions were removed; runtime validation remains unchanged. Re-run exact-commit CI before calling this milestone verified.

### Adaptive transport milestone (source after 24057a1a)
`24057a1a9d261de24d6ff414880757e71e691dee` contains the CI fixture corrections above. Its new CI is running; no pass claim yet.

Implemented next, pending exact-commit CI: existing `WindowsFirebaseRemote.prepareManagedBatch` uses a persisted per-school/per-profile window of 2–10 records. A failed/partial or >=8-second batch halves the next window; a fully verified <=2-second response grows it by one. Existing 250KB bound, parent/delete order, per-operation frozen requests, capability fallback, quota owner and individual ACKs remain unchanged. No scheduler or retry authority was added. Measurements cover the broker request only, not Android applied latency. Control Center displays actual last request timing, successful receipt count, next window and observation time; unmeasured state remains unknown. Focused regression retains all 12 queue operations through an interrupted 10-record batch, reloads the durable 5-record window, and proves that merely preparing successful receipts does not consume the queue. Policy tests cover slow/partial contraction and bounded recovery.

Modified: `lib/sync_recovery_policy.dart`, `lib/windows_firebase_sync.dart`, `lib/windows_sync_engine.dart`, `lib/windows_sync_control_center.dart`, corresponding tests and four-way review workflow. Exact-source Flutter analyzer/tests and broader workflow results are required next. No measured real-cloud speedup is claimed. No Apps Script/broker protocol change is needed for adaptive window; existing batch capability negotiation still gates it.

### Bounded durable replay milestone (source after 189a0fcd)
`189a0fcd8997853d0641e1958558e0c65a8b9fd1`: both exact-source push and PR repair workflows PASS; four jobs Windows/Linux × JSON/SQLite include owner, media and adaptive-window regressions. PR run 40259894053; push run 40259888743. Other current review workflows must still be checked independently.

Implemented next: partitioned metadata-only change replay in the existing Firestore hint owner, atomically with the legacy hot hint window. Pages hold <=64 events; <=32 pages retained per school/epoch (up to 2048 recent hints; oldest partial page may reduce effective history). One catch-up request reads at most two page documents and delivers <=64 events. Each PC retains its independent durable received/apply progress. Request flag `changeFeedReplayVersion:1` negotiates replay; older broker/client safely uses the existing reset/reconciliation behavior. Windows existing listener requests replay, with no new scheduler. Missing/foreign/corrupt/expired pages or a publisher from an older version force broad authoritative reconciliation; missing notifications never infer record deletion. School membership/device authorization is rechecked by the existing broker before returning data. Current Script `.2` is unchanged. No production rollout performed.

Local full backend **546/546 PASS** (source before the final sequence-overflow guard; rerun required for that final guard). Synthetic replay tests cover 1, 2 and 5 independent client cursors, 1000 hints recovered in 16 bounded responses per client after broker restart, old-client reset fallback, retention expiry, missing/foreign/truncated pages; the 15k notification stress fixture still passes with <=33 hint/page documents per school. This is synthetic metadata propagation, not a 15k end-to-end school-record/cloud/device benchmark. Metadata publication now writes a page plus the existing head; page rotation also deletes the expired page. This adds bounded Firestore metadata write cost and needs isolated provider quota/load acceptance before production.

Next precise steps: exact-source final CI; then bounded external Sheets edits/readable-projection audit, Android/Web resumable/persistent retry ownership, provider-supported resumable media, deeper recovery postconditions, full 15k record/device acceptance and real end-to-end measurements. These are unfinished; do not relabel this incremental PR as complete release-ready.

### Atomic replay and mobile quota milestone (source after b8d57f0d)
Previous replay commit: `b8d57f0df580b80269649baf781f3b7296997050`. Replay source including the overflow guard passed **546/546 backend tests** locally. Additional atomic replay fixture now models transaction commit/rollback and rejects Firestore read-after-write misuse; injected page-write failure preserves the original hint head and exact retry advances once. Legacy transaction adapters lacking delete retain the original hot-window behavior instead of accumulating unbounded replay pages. Full backend with this addition: **547/547 PASS** locally.

Mobile source: `lib/mobile/school_session.dart` now persists dashboard quota attempt/cooldown in the existing school/person-bound secure cache, rejects notification/resume/dashboard read bursts during a provider quota deadline, uses quota delay in the existing recovery timer, and preserves the prior verified dashboard timestamp and documents. It never acknowledges attendance or guarantees execution while Android is stopped. New test in `test/mobile_smart_sync_test.dart` verifies HTTP429, five duplicate signals, restart restoration, no extra network reads, and no false new verification. The same four-way exact-source CI now includes the mobile suite. These new Flutter changes require exact-commit CI before PASS can be claimed.

Precise remaining engineering is unchanged: external direct Sheet edit/readable-projection audit, provider-supported resumable uploads/downloads, full mobile/Web applied-cursor convergence/background ownership, additional evidence-gated repair playbooks and end-to-end performance acceptance. Existing complete-file hash-verified retry is not resumable transfer. Existing 64-page fallback and quota guards are not proof of real-school pending resolution. No production changes authorized or performed.

## Preserve the original rules
- School/profile identity isolation and signed authorization; never infer/migrate a school ID.
- Initial sync + hourly idle reconciliation, immediate changed-record dispatch, no-op Save, any-date same-record edits, first committed same-key Add.
- Durable offline queue; original operationId, immutable retry wire request and original captured time; no queue reset, blind overwrite, fake ACK, fabricated revision, or dropped pending entries.
- Single authoritative CAS owner; same-field conflict requires review; foreign school, quota, expired permissions, unknown errors stop unsafe execution.
- Student generations, financial event uniqueness, independent parent/file/delete order, receipt linkage, 24-hour recycle retention; recoveries must not resurrect deleted records.
- Durable received cursor is not applied/ACK cursor; point read never infers deletion. Media originals and previous verified cache remain intact.
- No new Firebase project, paid external AI/API, production data migration or forced Apps Script replacement.

## Remaining work: specific order for ChatGPT chat mode, Codex or Work
### Phase A — integrated intelligent self-repair (NOT a new engine)
- Source: `lib/windows_sync_engine.dart`, `lib/windows_pending_school_sync.dart`, `lib/windows_sync_recovery.dart`, `lib/sync_recovery_policy.dart`, `lib/windows_binary_downloads.dart`, `lib/windows_sync_inbox.dart`.
- Build an allowlisted, evidence-gated repair matrix per failure category with precondition, existing owner action, verified postcondition, persisted cooldown/budget, and fail-closed escalation. Add targeted safe actions for resumable read-only diagnostics, verified media refetch, durable inbox catch-up, lost-ACK idempotent readback. Treat `retry_admitted` separately from `repaired_and_verified`. Do not promise 1000 auto fixes, train repair privileges from logs, or retry quota/auth/conflict blindly.
- Verify per school: crashes at each storage boundary, two concurrently running Windows clients, five devices, original queue IDs, mixed late receipts, every blocked category and reboot after each stage.

### Phase B — event delivery, scaling and platform convergence
- Sources: `functions/school-change-feed.js` (currently 64 recent hints per school), `functions/school-sync-delivery.js` (512 pending tickets per school), `lib/windows_remote_change_feed.dart`, `lib/windows_sync_inbox.dart`, `lib/windows_sync_engine.dart`, mobile school session and managed Script.
- The 64-event bounded hint window correctly forces a broad catch-up; design a *backward-compatible, partitioned, durable* event log with independent applied cursor, token ordering, exact-record changed hints and gap audits. Preserve server-side signed school checks and old protocol fallback.
- Validate the 512-intent hot document with 1,000+ synthetic concurrent events before sharding. Introduce capability negotiation, migrations only with safe rollback, per-device catch-up, Android page checkpoint pagination and web live refresh. Do not claim real-time instant delivery on a cold/over-quota Google Script.

### Phase C — performance, media and Sheets-integrity
- Preserve current capability-gated field patches, individual batch receipts (max ten), separate dependency ordering, canonical file hash verification, no-op saves and verified baselines.
- Add measured adaptive batches/backpressure, low-latency priority for newest edits and attendance, separate slower bulk media lane; keep quota and rate-limit hard stops. If chunk/resume is supported by the provider, implement upload/download journal, byte-offset, hash, non-resurrection and old-client fallback; never relabel incomplete transfer as ACK.
- Detect external direct Sheet edits that bypass sync revision metadata through a bounded owner-approved reconciliation/integrity audit. Do not equate missing point-read rows with tombstones.

### Phase D — reliability, observability and acceptance
- Respect OS rules: Android WorkManager may defer background jobs; Windows terminated process currently has no service. Any optional service needs single-owner leases and a tested handoff rather than two writers.
- Measure monotonic local Save → dispatch → Render/broker → Apps Script/Drive/Sheets durable ACK/readback → Android/Web applied, separately for each record. Record p50/p95/p99, queue depth, actual bytes, retries, quota, and integrity without recording pupil PII or credentials.
- Isolated TEST school only: real two-PC plus Android/website, explicit injected 401/403/409/429/502/503/timeouts, Wi-Fi cut, sleep/wake, hard kill/restart, 24h recycle boundary, 1k/5k/15k load **only with signed quotas/fixtures and reserve capacity**. Synthetic CI is not provider throughput/physical acceptance.

## Independent deployment gates
- Backend source merge and GitHub code publication do not update private schools' Apps Script web-app deployments. PR #134 requires matching `2026-10-25.2` Script bundle and broker; preserve school root, secret, properties and `/exec` URL. Old Script capability must retain safe fallback.
- At checkpoint the production broker was deployed on commit `533c49d0a9abb9abf67fc05894e3ba9d42549490`; its branch is independent of main. Compare and test before any deploy.
- Review exact CI results. Do **not** merge or publish Windows/Android/website/broker or touch real-school records until compatibility and release gates pass and the owner explicitly approves.
- If access to private school Script/physical hardware is unavailable, continue independently implementable work and report only precise remaining blocked acceptance, never claim pending queue cleared.

## Resume instructions (human or next AI session)
1. `git fetch` / inspect current main, this branch HEAD, draft PR, pending CI. Never reset/restart completed work.
2. Read this file, `docs/intelligent-sync-owner-upgrade.md`, `docs/smart-sync-record-rules-20261025.md`, `docs/record-only-sync-20261018.md`, `docs/high-performance-sync-acceptance.md`.
3. Run `flutter analyze lib/windows_pending_school_sync.dart lib/windows_remote_change_feed.dart test/windows_sync_intelligent_repair_test.dart test/windows_remote_change_feed_test.dart` and `flutter test --concurrency=1 test/windows_sync_intelligent_repair_test.dart test/windows_remote_change_feed_test.dart` in default and `--dart-define=SAARTHI_WINDOWS_SQLITE=true` modes. Also run backend tests, multi-PC, lifecycle and document/owner suites relevant to modifications.
4. Record exact source SHA, pass/fail/skipped, test artifact links, version compatibility and last successful real-school ACK proof in PR. If any failure, fix within this branch and preserve original queue invariants.
5. Implement phases A-D incrementally with real regression evidence; don't replace this file with a broad completion claim.
