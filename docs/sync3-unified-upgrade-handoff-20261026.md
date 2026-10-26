# Sync Engine 3 unified upgrade — authoritative continuation
Updated 2026-10-26 after final exact-source CI. This checkpoint supersedes older milestone notes.

## Repository and safety
Repository: cscticket01-hash/Saarthi_Ai
Branch: feature/sync3-unified-repair-20261026
PR: https://github.com/cscticket01-hash/Saarthi_Ai/pull/135 — OPEN, DRAFT.
Latest implementation/test commit: 459d34fc2c3ccd2bf41e1dc103d3c542ee1743bd.
Main verified unchanged: 9c1cacd6cef905490e5249cc0958ae686dc4e68f.
The following documentation-only commit records this checkpoint; inspect current PR head before editing.

Keep one existing Sync Engine 3 owner, policy, queues, journals and verified ACK path. No separate repair engine/scheduler, paid AI, queue reset, security bypass or school migration. Preserve original operation IDs/revisions/times, financial uniqueness, school isolation, 1–5-PC policy, offline durability, immediate changed-record work, hourly idle reconciliation, no-op saves, true conflicts and student tombstone/generation/recycle protection. Notifications received are not applied ACKs. Missing records alone never authorize deletion/restoration.

## Implemented milestones and commits
- Existing owner improvements through 19c6c489788252886dcd6c431b27a67d7b54a683: bounded 40s diagnosis, durable five-attempt automatic repair budget, cooldown/escalation, protected error classification, exact operation journals; adaptive 2–10-record batches with individual receipts; bounded durable hint replay, gap reconciliation and Android persistent quota deadlines.
- 15c3f560ba2f456aec5ff3bdf3eb18d6326430e3: school-scoped shared listener multiplexing, 2500 total bounded waiters, 30s listener idle grace, 400-school regressions; signed bounded external-Sheet audit integrated into existing Windows owner and Control Center.
- 40ee05f56d742969ae8409119cd9fc6d2b3a3e65: verified resumable client-to-broker binary downloads and durable prefix journals; complete-group checkpoint body fallback under 200KB.
- d8648181fc3dca8c77a984196ba0eb8f8e8b5ff1: Android oversized-cache fallback; website school-switch isolation, late-response fencing and applied-snapshot validation; separate read-only isolated TEST readiness workflow.
- 20c9920d2cc0ad94a040a971256d53ecca343df9: full/point authoritative reads reject unproven external row/head drift; actual 100k-student Script fixture and dedicated CI; sanitized TEST entitlement diagnostics.
- 49ab46cdd7b40c21a252992f4a245d57b536f5fd: optional audit requires BOTH broker and Script capability (safe mixed upgrade order).
- 459d34fc2c3ccd2bf41e1dc103d3c542ee1743bd: 1, 2 and 5 independent SQLite cache files, offline disjoint same-record edits, reverse reconnection, original operation IDs, verified receipts and no-op save regressions. No runtime change in this last test commit.

## Files / behavior
Owner/recovery: lib/windows_pending_school_sync.dart, lib/windows_sync_engine.dart, lib/sync_recovery_policy.dart.
Transport/media/feed/monitor: lib/windows_firebase_sync.dart, lib/windows_binary_downloads.dart, lib/windows_remote_change_feed.dart, lib/windows_sheet_integrity.dart, lib/windows_sync_control_center.dart.
Platforms: lib/mobile/school_session.dart, lib/managed_school_live_view.dart.
Backend: functions/school-change-feed.js, functions/managed-schools.js, staging-school-cloud/server.cjs.
Script: school-backend/managed/SaarthiManagedAdapter.gs and generated SaarthiManagedAll.gs.
Focused regression files and GitHub workflows accompany the source.

Sheet audit checks at most 25 existing authoritative heads/page. Reports canonical/readable projection drift and missing live rows, retains tombstones and never imports unverified external edits or restores a deleted row. Signed nonce bookkeeping remains. Writer/readback fail closed with SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED; proven identical authenticated full-snapshot lost-ACK repair is preserved. Windows persists bounded audit cursor and reports last-page findings, not whole-school health.

Media uses optional binaryRangeVersion:1, exact school/file/hash/version/offset binding, chunk and final hashes, durable prefix journal, corrupt partial quarantine and previous verified-file fallback. Broker cache is bounded to 24MB/two-minute lazy expiry/two distinct upstream reads. Cold broker may still fetch the complete provider file. This is NOT native Drive resumable upload. No Drive originals are changed.

Android complete checkpoint groups over budget fall back safely rather than truncate. Website school switch clears old private state and rejects late responses; revisions cannot advance without an applied or verified unchanged snapshot. Existing leased attendance WorkManager remains; no competing background dashboard writer was introduced.

## Exact-source verification: 459d34fc2c3ccd2bf41e1dc103d3c542ee1743bd
All NINE unique code/regression workflows completed SUCCESS (plus duplicate push repair review):
- Unified repair: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666244 — four Windows/Linux JSON/SQLite jobs, 88 tests each.
- Record capacity: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666255 — actual 100,000 synthetic student records across 400 isolated school VMs; authenticated commits/readbacks, duplicate retries and foreign-school rejection.
- Multi-PC: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666546 — Windows AND Linux PASS; each 15 correctness +2 load +102 retained regressions, including independent 1/2/5 SQLite cache cases.
- Platform: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666556 — backend 564/564, OAuth 19/19, security, Web, Android, Windows compile/crash recovery/fresh-start/restart smoke PASS. Original gated isolated-cloud job SKIPPED, not acceptance evidence.
- JSON: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666327
- Documents/student Sheet: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666253
- Sheet recovery/lifecycle: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666521
- Duplicate Save: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666285
- Standalone guardian removal: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666588
Local backend 564/564 PASS, syntax and diff checks PASS. Flutter evidence is GitHub CI; no local Flutter SDK. Existing nonfatal analyzer warnings were not disabled or represented as zero warnings.

## Measured scope and limits
Actual Script/CAS/Sheet fixture: 400 sequential school VMs x250 students =100,000 committed/readback records; 400 duplicate retries prevented and cross-school writes rejected. Local run 305.107s, peak RSS approximately209.6MB. Earlier CI checkpoint20c992:118.451s, approximately120.9MB. Runner/fixture timings, not real provider throughput or a measured speedup.
Metadata fixture separately covers100k hints,1200 independent cursors and2000 waiters sharing400 listeners. Not100k concurrent devices. Existing15k fsync attendance component uses mocked remote ACK.
No real-cloud end-to-end latency, physical-device throughput or production capacity guarantee measured. School-count and stored-student count alone do not establish peak load. Official provider limits checked2026-10-26: https://firebase.google.com/docs/firestore/quotas and https://developers.google.com/apps-script/guides/services/quotas . Free-tier limits still apply; no billing or paid service enabled.

## Separate real TEST acceptance: BLOCKED / workflow FAIL
https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40269666267
Existing TEST school vs-db8afb01a3be46a983c8284714d06e5d at https://saarthi-sync-v2-test.onrender.com/school-cloud .
Firebase health200, unauthenticated401, foreign-school403, Firebase login200 and own authenticated identity200 PASS. Own profile403: entitlement allowed:false,status:expired,activated:false, expiresAt1792684422069 (22Oct2026 21:23:42.069 IST). Do not bypass/disable licence checks or silently renew.
Deployed TEST runtime91b4282bf900ade767f5a12567ee22b2543e4a3f is NOT this PR. No new-source deployment or real-school modification occurred. Existing GitHub TEST secrets already work; never request passwords/tokens in chat. Browser console unavailable/timed out; no entitlement document edited.
The separate readiness workflow correctly fails; do not call all CI green or full real-cloud acceptance passed.

## Remaining work, dependencies and precise next step
1. Authorized TEST entitlement renewal and matching isolated deployment are prerequisites to real-cloud acceptance. First inspect TEST management/entitlement state read-only when available; do not expand access or modify production without required authorization.
2. Run signed cloud/Drive/Sheets compatibility, 1/2/5 physical Windows devices plus Android/Web, provider quota/load and Save-to-ACK-to-apply timing acceptance. Keep synthetic and physical evidence distinct.
3. Native provider resumable UPLOAD needs a supported negotiated provider contract; current idempotent verified full-upload fallback is retained. Do not mislabel download resume as upload resume.
4. A new background dashboard writer requires proven shared foreground/background cache ownership/fencing; existing attendance worker is unchanged. OS-stopped execution cannot be guaranteed.
5. Continue independent owner playbook/integrity regression work if evidence identifies gaps, without creating another engine or making unverified repairs.

Optional new Script bundle2026-10-26.1 and corresponding broker are NOT deployed. Existing2026-10-25.2 remains supported via capability fallbacks; preserve URLs, school IDs, Drive roots, credentials/properties. Both capability flags are required for new audit. No main merge, production Render change, private school Script edit, Windows/Android installer publication, website publication or real-school writes authorized/performed.

Release status: DRAFT; code/regression CI PASS on implementation459d34f, separate real TEST acceptance BLOCKED. Entire A–J production certification is incomplete. The next documentation-only head may retrigger workflows; distinguish its status from this verified implementation.
