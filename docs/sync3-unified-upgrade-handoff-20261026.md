# Sync Engine 3 unified upgrade — authoritative continuation

Updated 2026-10-26. This checkpoint supersedes older blocked/missing-implementation milestone notes. Re-read the current PR head and latest acceptance artifacts before continuing.

## Repository and deployment boundary

- Repository: `cscticket01-hash/Saarthi_Ai`.
- Upgrade branch: `feature/sync3-unified-repair-20261026`.
- PR: https://github.com/cscticket01-hash/Saarthi_Ai/pull/135 — OPEN, DRAFT.
- Reviewed deployment checkpoint: `b68bf194a49899232544ea9ea16f5e64410aad15`; merge tree matches the reviewed `3bfb9ff` implementation tree. Both upgrade and isolated TEST branches were advanced without discarding TEST history. The only unique old TEST first-pairing patch was already present in the upgrade, including its passing regression.
- Existing isolated Render TEST service only: `srv-db3tgfu7bikc73abm7a0`, endpoint `https://saarthi-sync-v2-test.onrender.com/school-cloud`.
- Deployment `dep-dbfgv77b9u1s73ctm48g` is LIVE at the reviewed checkpoint.
- Production/main, production broker, published website and Windows/Android installers were not changed during this continuation. No real-school records were modified.

Keep the one existing Sync Engine 3 owner, queues, journals and verified ACK path. Do not introduce another repair engine or scheduler. Preserve original operation IDs/revisions/timestamps, financial uniqueness, school isolation, the 1–5-PC policy, offline durability, immediate changed-record work, hourly idle reconciliation, no-op saves, true conflict review and student tombstone/generation/recycle protection. Notifications are not applied ACKs. Missing rows alone never authorize deletion or restoration. No queue reset, paid AI, security bypass or storage migration.

## Implemented behavior

- Existing owner: bounded diagnosis, durable five-attempt automatic repair budget, cooldown/escalation, protected error classification and exact operation journals; adaptive 2–10-record batches retain individual receipts.
- Feed: school-scoped listener multiplexing, bounded durable hint replay/gap reconciliation, 2,500 total bounded waiters and 30-second listener idle grace. Android persists quota deadlines.
- Integrity: signed bounded external-Sheet audit through the existing Windows owner/Control Center; at most 25 authoritative heads per page. Reports canonical/readable drift and missing live rows, retains tombstones, and never imports unverified edits. Reads/writes reject unproven drift with `SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED`; identical authenticated full-snapshot lost-ACK repair remains supported. Audit reports page coverage, not whole-school certification.
- Downloads: negotiated exact school/file/hash/version/offset binding, chunk/final hashes, durable prefix journal, corrupt-partial quarantine and previous verified-file fallback. Broker cache remains bounded to 24 MB/two-minute lazy expiry/two upstream reads. A cold broker can still fetch a whole provider file.
- Native Drive resumable uploads: implemented in broker, Script and existing Windows upload owner. Stable upload key, private provider session, fixed preallocated Drive file ID, authoritative offsets, per-chunk hash and independent final metadata/full-content verification. No uncertain-upload fallback to a second writer. Both broker and Script flags are required; old/opt-out/small-file paths retain verified full upload. See `docs/sync3-native-upload-20261026.md`.
- Android: encrypted SQLite shared snapshot with secure-storage key, independent foreground/background connections, version CAS, account/QR isolation and logout tombstones. Existing attendance WorkManager invocation reconciles dashboard only under the existing idle policy and closes transient resources. No extra scheduler. See `docs/sync3-background-cache-20261026.md`.
- Website: school-switch state clearing, late-response fencing and applied-snapshot validation; revisions cannot advance without an applied or verified unchanged snapshot.

Core files include `lib/windows_pending_school_sync.dart`, `lib/windows_sync_engine.dart`, `lib/sync_recovery_policy.dart`, `lib/windows_binary_downloads.dart`, `lib/windows_sheet_integrity.dart`, `lib/mobile/session_cache_store.dart`, `lib/mobile/school_session.dart`, `lib/mobile/attendance_background.dart`, `lib/windows_connect/managed_resumable_upload.dart`, `functions/managed-schools.js`, `functions/school-change-feed.js`, and the canonical managed Script components plus generated `SaarthiManagedAll.gs`.

## Current code and readiness evidence

All nine code/regression workflow categories passed at the reviewed checkpoint: unified repair, 400-school record capacity, multi-PC sync, platform builds/security/backend, JSON storage, document/student Sheet, Sheet recovery/lifecycle, duplicate Save, and standalone guardian removal. Guardian removal verifies the old separate engine remains removed.

Exact deployed-source and Script readiness run **40291949316 PASS**:
https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40291949316

This establishes the matching isolated runtime/Script and authenticated readiness, not full native-upload, quota, latency or physical-device acceptance. Existing nonfatal analyzer warnings were not disabled or represented as zero warnings. Flutter execution evidence comes from GitHub CI; no local Flutter SDK is installed.

Historical source-specific evidence, retained for traceability:
- At `79bcaaa3d0dc55d7aeaed8a88c5683b4ee587487`: 574/574 backend tests; 97 focused tests on each Windows/Linux × JSON/SQLite owner job; nine code workflow categories PASS. These counts describe that source, not every later commit.
- At `459d34fc2c3ccd2bf41e1dc103d3c542ee1743bd`: earlier owner/multi-PC/capacity milestone passed. Later changes supersede its implementation and deployment status.
- The original TEST runtime `91b4282...` and expired entitlement were previous blockers. Both were resolved for isolated TEST after explicit user authorization; do not report them as current blockers.

## Existing TEST school: resolved setup prerequisites

Canonical school: `TEST Sync V2`, ID `vs-db8afb01a3be46a983c8284714d06e5d`.

The user authorized one seven-day complimentary TEST licence. Scoped administrative transaction issued/activated a normal school-bound licence, preserving the original trial metadata and all storage configuration. Expiry is **2026-11-02T08:15:29Z** (13:45:29 IST). Fixed operation marker `sync3-test-seven-days-20261026` prevents reruns from extending it again. No permanent bypass was added. Existing GitHub TEST secrets work; never request or print passwords, keys or tokens in chat.

The existing TEST Apps Script project, whose ID begins `1fH0`, was updated to deployment **version 13**, bundle **`2026-10-26.2`**. Existing `/exec` URL, school ID, Drive root, workbook IDs, signing secret and other properties were preserved. No setup/create-new-storage operation or replacement project was used.

TEST-account Drive REST GET and root capabilities were verified. TEST Script property `VS_NATIVE_RESUMABLE_UPLOAD=1` was enabled. The temporary owner-editor helper used for verification was removed; no helper code remains in the deployed project. This flag is TEST-only and does not imply other schools have opted in.

## Real acceptance in progress: do not claim complete

- First native-upload acceptance attempt reached an **HTTP 413 ingress rejection before the first upload chunk**. It did not establish successful native upload. A transport-size correction is being implemented/reviewed separately; inspect the latest head, tests and exact-source deployment before rerunning.
- Cloud prerequisites run **40291954545**, original job **121468858495**, failed before any login/pairing/fixture call: it waited 08:25–08:31 UTC for exact `b68bf194...` deployment and ended with `checks: []`. This was a deployment race, not evidence of storage corruption. Its rerun was started after matching deployment/readiness passed; check the rerun result before making acceptance claims.
- `connect_isolated_test_storage.cjs` sends the existing approved URL without replacement permission. Ready same-URL pairing is a signed health read; a different stored URL rejects with 409. Subsequent `VS_TEST_REAL_SYNC=true` steps intentionally create bounded synthetic TEST records, a Drive fixture and attendance, scoped by hosted attempt identity, and refuse non-synthetic collisions.
- No successful real native resumable upload, network interruption/resume, live quota/load limit or complete cross-platform acceptance is certified by this checkpoint.

## Measured capacity and practical limits

Synthetic Script/CAS/Sheet fixture: 400 sequential isolated school VMs × 250 students = 100,000 committed/readback records, with 400 duplicate retries prevented and foreign-school writes rejected. Independent SQLite cases exercise 1, 2 and 5 PCs, offline disjoint same-record edits, reverse reconnection, original operation IDs and verified receipts. Metadata fixture separately covers 100,000 hints, 1,200 cursors and 2,000 waiters sharing 400 listeners.

These are synthetic capacity/correctness fixtures, not 100,000 concurrent devices or a real-provider throughput guarantee. Historical local record fixture timing 305.107 seconds/approximately 209.6 MB peak RSS and earlier CI timing 118.451 seconds/approximately 120.9 MB describe different runners, not a measured product speedup. The retained 15,000-operation fsync attendance component uses mocked remote ACK.

No billing or paid service was enabled. Provider quotas remain workload constraints. Official quota references checked 2026-10-26: https://firebase.google.com/docs/firestore/quotas and https://developers.google.com/apps-script/guides/services/quotas .

## Remaining acceptance and release gates

1. Finish the HTTP 413 correction, run focused/full code tests as appropriate, update only the isolated TEST runtime, and rerun native upload acceptance against exact reviewed source.
2. Complete real Drive/Sheets protocol compatibility, fixed-file identity/hash readback, interruption/lost-ACK/resume, safe quota-response and Save → cloud ACK → receiver apply timing checks. Preserve all uncertain pending work.
3. Review rerun cloud prerequisites and subsequent hosted Windows/browser/Android-emulator evidence. Label hosted/emulator results accurately; these do not replace physical tests.
4. Physical Windows 1/2/5-PC plus Android/Web acceptance remains pending. Android minimize/background, reboot/force-stop/battery/network cases require real-device verification; OS-stopped execution cannot be guaranteed.
5. Append final acceptance artifacts and commit-specific code evidence, then reassess release readiness. Keep PR DRAFT while material acceptance remains unresolved. No production/main merge or installer publication is performed by this checkpoint.

Continuation must distinguish code tests, exact readiness, real-cloud protocol acceptance, emulator tests and physical-device acceptance. Never turn a pending or skipped gate into PASS, and do not redo completed setup or extend TEST access automatically.

## Native ingress correction prepared after real TEST failure
The real native fixture reached the broker but its first 256 KiB binary chunk exceeded the ordinary 256 KiB JSON ingress cap (HTTP 413). The central server now admits only native `part` envelopes up to 700000 base64 characters +4096 JSON bytes; ordinary JSON and existing full-upload limits remain unchanged. Actual HTTP 256/512 KiB regressions and oversized/anonymous rejection pass. Broker suite20/20 and harness6/6 PASS. Deploy this correction to isolated TEST and rerun the retained original upload key; real completion is not yet claimed.
