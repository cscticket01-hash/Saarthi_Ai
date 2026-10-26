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
