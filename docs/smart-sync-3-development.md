# Smart Sync 3.0 development evidence

Branch: `feature/smart-sync-3`; draft PR #23. Main starts at `de547d2c0a025db815ce97479e3f4f3fc4f8f1a8`. Production publication is not authorized.

## Current implementation (2026-10-10)

The existing local-first engine remains authoritative: durable SQLite writes enqueue original operation IDs, versioned cloud ACKs remove only the acknowledged queue version, and later edits survive failed requests and stale pulls. Changes add bounded recovery, hourly/wake scheduling, protected cache recovery, recycle inventory/restore, TEST recovery rehearsal, media-original retention and measured monitoring.

The control center now shows own-profile category counts, actual queue/conflict/document state, verified receipts, last ACK/reconciliation/backup, next hourly checkpoint, local application byte measurement, authenticated school API health and timestamped own-school Drive usage. Partial Drive inventories are labelled lower bounds. Local application bytes include all local profiles and backups and are explicitly labelled. Unknown download inventory remains unknown. Sanitized export excludes raw payloads, credentials, paths and record identifiers.

Central monitoring accepts bounded client version/conflict/document/checkpoint fields, replaces the whole report to prevent stale optional metadata, and distinguishes client observations from server durable-ACK evidence. Reports older than ten minutes are stale. Successful server evidence clears residual failure fields.

Offline tracked deletes now retain their original local snapshot and stable delete operation ID in the same database transaction as the hidden row and outbox. Snapshots remain school-scoped and survive restart. A verified durable delete receipt records the deletion revision without removing the original snapshot. Failed/unacknowledged deletes stay unverified; financial evidence and file bytes are not purged. This preservation does not implement an offline restore choice.

## Verified acceptance (2026-10-10, UTC)

Application/runtime commit: `0a3a4ead56646e8069865347bc3addf04f53dc43`. Documentation-only commits do not change this tested runtime. Existing TEST Apps Script Version 7 is unchanged.

| Acceptance | Verified result |
| --- | --- |
| Platform push / PR | All five jobs PASS in 38031214142 and 38031218222: Windows, Android, Web, backend, school-security. |
| Windows durable SQLite | 25 SQLite tests PASS, including original offline financial delete snapshot, stable delete ID, school isolation, reopen and verified-ACK linkage. Production screen/queue/startup group: 93 PASS. OS process crash recovery PASS; EXE build/restart smoke PASS. Suite groups overlap and must not be summed as unique tests. |
| Backend / OAuth / rules | 268 backend, 14 OAuth and 25 Firestore isolation/security regressions PASS; seven runtime/provenance tests PASS. |
| Real TEST cloud | All five jobs PASS in 38031214129: signed preflight, production-class engines, Chromium UI, Android API 35, native Android-to-Windows readback. Exact deployed runtime identity verified before pairing or fixture writes. |
| Preflight / measurements | 32 pairing/live checks and 10 read-only prerequisite checks PASS, including own-school measured Drive usage and monitoring readback. Fresh attendance queue-to-ACK: 10,821 ms. |
| Production-class engines | Local SQLite durable save: 44 ms; Windows queue-to-ACK: 9,513 ms. Controlled client-boundary 502 retains original operation, followed by automatic jittered retry and actual cloud ACK/readback. Photo original retained after SQLite reopen, duplicate cloud upload idempotent. |
| Chromium | Real school login, Windows notice visibility, CAS write/readback, persisted offline draft/reload and duplicate ACK/readback PASS. Website write/readback: 31,642 ms. |
| Native Android | Native SQLite/secure-storage plugins and production dashboard PASS. Injected offline-boundary save: 37 ms. Queue-to-verified cloud read: 59,782 ms. Windows and website notices visible without Windows running. This is an emulator/injected-boundary test, not physical Wi-Fi or process-kill acceptance. |
| Native Android to Windows | Original capture time and record integrity PASS; newer local edit protected; foreign school rejected. Windows cloud read: 11,250 ms. One deliberately created newer local edit remains durably pending. |
| Disaster / monitor | Eight checks PASS in 38031214153: original operation resumed, complete archive and separate Sheets/Drive restore readback, active revision/operation/timestamp/file link unchanged, original bytes retained, foreign school rejected. **348 records and 19 uploaded binaries** restored into private TEST recovery storage. Monitor server durable ACK verified, residual failure code absent; no Windows report was observed and stays unknown. |
| TEST deployment | Render `dep-db4tnf7lk1mc7380h3ug` live at the tested application commit, 06:32:05.999 UTC. Production untouched. |

The first-frame Android harness change passed fresh native acceptance; the previous APK-install/driver hang did not recur. The twelve-minute driver timeout remains a bounded failure path, not a substitute for successful evidence. Earlier interrupted recovery checkpoints were retained and the final same-operation readback passed; the prior generic restore exception is not retrospectively assigned an unproven cause.

Full active disaster cutover, never-uploaded queues and Firebase credentials are **not included** in the cloud rehearsal. No active storage pointers or original school data were replaced.

Local Flutter setup was automatically blocked after cloud metadata endpoint access was detected. That setup route was not retried; Flutter verification completed through existing GitHub CI.

## Latest hosted verification (2026-10-10, UTC)

Exact reviewed source: `f6fe4a1ebe79104fc0e462eb7a83a66fb2d9744d`; [Platform review builds run 38033317079](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38033317079) completed **success** after rerunning the failed job.

| Job | Result |
| --- | --- |
| Backend | PASS, including backend regression checks, OAuth broker security tests, unpublished container build, and safe Google Desktop OAuth configuration probe. |
| Windows | PASS, including SQLite migration/integrity/atomicity and production API regression, Windows app analysis/tests, compile, fresh-start/duplicate-launch/restart smoke, and exact-commit review package. |
| Android | PASS; shared Windows QR compatibility checks and unsigned review APK build passed. |
| Web | PASS; platform analysis/regressions and developer website build passed. |
| Firestore school security | PASS; emulator rules isolation checks passed. |
| Isolated TEST cloud | SKIPPED by this workflow's branch condition. This run supplies no new live-cloud or physical-device acceptance. |

The initial attempt stopped in the safe OAuth probe after its 90-second health check and emitted only the generic failure message. The rerun passed the same probe. The underlying cause of the first timeout remains unconfirmed; no credential, OAuth configuration, or staging deployment was changed. Review artifacts were created for `windows-review-build`, `android-review-apk`, and the web preview. These are unpublished CI review artifacts, not release downloads.

Read-only Render inspection found no staging application/request/error logs or service events in the initial OAuth probe window. This leaves the probe timeout's cause unconfirmed. The original school incident is an Apps Script `HTTP 502 / SCRIPT_OPERATION_FAILED`; Apps Script execution logs for that school were not available through the connected tools, so its exact exception remains unverified. Its three pending fee/document operations remain untouched.

This run does not close the remaining production limits below: integrated local snapshot restore, pending-download inventory, clean-install disaster cutover, physical device/sleep/wake/media checks, real provider concurrency, and the original school's HTTP 502 cause remain unresolved or unverified. The prior TEST cloud and disaster-recovery evidence remains tied to its stated runtime and runs; it is not reclassified as part of run 38033317079.

## Fourteen requirements

| Requirement | Current implementation / remaining acceptance |
| --- | --- |
| Full control center | Measured health/storage/category/queue controls implemented; pending-download inventory and full clean-install restore remain incomplete. |
| Intelligent safe repair | Bounded typed retries, retained conflict history and explicit financial review implemented; unknown errors retain data. Original incident cause remains unconfirmed. |
| Hourly standby | Hourly/wake/reconnect scheduling tested with controlled timers; real elapsed-hour and physical sleep/wake remain unverified. |
| Instant local entry sync | Local durable saves and versioned TEST cloud ACK evidence exist; infrastructure latency is measured, not guaranteed instant. |
| Bidirectional recovery | Missing local-cache inventory, pending-edit/tombstone protection and verified cloud-record backup recovery implemented; fresh live cloud chain and bounded record/archive recovery pass; full clean-install activation remains unverified. |
| Protected 24-hour recycle | Signed cloud snapshot/restore, TEST expiry scheduler and local inventory UI implemented; offline local snapshot preservation added; integrated local restore remains incomplete. |
| Android independent of Windows | Shared school session and native harness implemented; fresh current-commit Android API 35 dashboard/session/cloud acceptance PASS; physical-device acceptance remains. |
| Offline attendance | Durable SQLite queue, original capture time and duplicate protection implemented; fresh native SQLite/secure-session reopen and injected-offline real-cloud acceptance PASS; physical restart/network acceptance remains. |
| Massive concurrency | 1k/5k/15k durable component benchmark passes with mocked delivery; no measured provider throughput claim. |
| Photos | Original retention, distinct-original identity, approximately 30 KB best effort and actual synthetic cloud readback implemented; representative visual quality remains unverified. |
| Documents | Original retention, durable queue and approximately 50 KB best effort implemented; physical scan/seal/signature legibility acceptance pending. |
| Disaster recovery | Hash-verified local staging and separate private Sheets/Drive rehearsal implemented; 348-record/19-binary private cloud rehearsal PASS; clean-install active cutover remains incomplete. Cloud cannot recover never-uploaded queues or credentials. |
| School isolation | Backend/Firestore/session tests and historical TEST foreign-school rejection pass; fresh exact-commit live foreign-school rejection PASS. |
| Accurate central monitoring | School-scoped timestamped storage and separate client/server evidence implemented; fresh server durable-ACK and own-school measured-storage acceptance PASS; latest Windows client/fleet report was not observed and stays unknown. |

## Device acceptance procedure

Use only the isolated TEST school and preview artifacts from the exact tested commit. Record device/app commit, server commit and clock before starting. Create synthetic entries offline; record operation IDs, original timestamps and retained source bytes; close/reopen and confirm the queue and local snapshots persist. Reconnect, wait for actual durable ACK, retry the same operation, and read back the unchanged capture time without duplicates. Keep an independent pending edit during reconciliation and verify it remains.

For standby, keep the app open for a full elapsed hour, then separately sleep/wake and disconnect/reconnect; record actual checkpoint timestamps and absence of overlapping sync. For media, inspect representative photos, fine print, handwriting, signatures and seals before approving readability. For recovery, stage a verified local backup into a fresh directory and a cloud archive into a separate TEST workbook; compare every manifest hash, record/tombstone count and queue operation ID before any explicit clean-install activation. A staging pass does not certify active cutover.

Live 1k/5k/15k simultaneous provider tests require a separately approved capacity exercise and representative permits, cost/quota budget and measurement; a local/mock benchmark cannot substitute.

## Original-school incident

Request `7a8e0438-cc6c-443b-947b-14f7eb68f86f` at `2026-10-09T14:59:01.439Z`: HTTP 502, `SCRIPT_OPERATION_FAILED`. Underlying Apps Script category/source line remains unconfirmed. The original fee and two document pending entries remain untouched. No main merge, production release/deployment, billing change or pending clearing is performed.

Production readiness: **BLOCKED** until the explicitly incomplete clean-install/offline-restore/download-inventory requirements and physical/capacity acceptance are resolved. All listed hosted current-application acceptance runs PASS. Historical passes are not relabelled as current-runtime evidence.


## Continuation changes (2026-10-10, current session)

Starting HEAD was verified as `0265ba0ae96a5a0ccf2b8f49d5d8347f0136411e`, PR #23 OPEN/DRAFT, exact-HEAD platform run [38035001784](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38035001784) SUCCESS. Historical cloud/runtime evidence above remains historical.

- Backup rehearsal now resumes a separately staged copy bound to the original manifest digest and resolved source/destination. Reused files are rehashed, interrupted staging bytes recopied, and unexpected files, links, changed backup generations and unowned existing folders rejected. The UI uses a stable `restore_rehearsal` child; select the same parent to resume. A sibling checkpoint remains for review. This is **staging only**; school-bound clean-install activation, credential reauthentication and path rebasing are still incomplete.
- Managed reconciliation now persists school-scoped, per-collection **record-only** download observations. Every admitted response is validated for school identity before its inventory is saved. Successful local record readback requires full canonical content equality after storage; protected pending edits are retained and counted as awaiting review. Interrupted observations survive storage/restart and are shown as requiring retry when sync is idle. UI explicitly keeps binary/media inventory Unknown and overall inventory Partial. These local download receipts are not server durable upload ACKs.
- Added regression coverage for interrupted resume, incomplete staging file repair, changed backup rejection, existing-data containment, extra-file rejection, record readback and protection of newer local edits/operation IDs. Flutter verification must come from exact-commit hosted CI; Flutter/Dart is unavailable locally. No attempt was made to repeat the previously blocked SDK setup route.

Local Node 24 backend regression: **268 PASS / 0 FAIL** after installing declared dependencies. Initial dependency-free attempt had **263 PASS / 1 failed test file** because `firebase-admin/app` was unavailable; this was an environment failure, resolved by dependency installation. No application/backend change was made to obtain a pass. Hosted Node 22 and Flutter checks remain pending at commit preparation. `git diff --check` passes.

Next: inspect exact-commit platform results before treating these source changes as verified; then implement school-bound clean-install activation and offline local snapshot restore without clearing/replacing original deletion intents, measure binary download inventory, and execute isolated TEST cloud client acceptance at the new source commit. Production must remain blocked. Physical full-hour/sleep/wake/network/24-hour expiry, representative media inspection, provider capacity approval and original-school Script execution diagnostics remain outstanding. No original school records, pending operations, credentials, production settings, main branch, releases or public links were changed.


### Exact-source hosted results and TEST runtime

Application/engine commit `33767380ad3e5635824cc94808aabdea5184a27d`: [platform PR run 38070712665](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38070712665) has **all five platform jobs PASS**. Windows logs record **25 SQLite tests, 96 production SQLite recovery/screen/queue/startup tests, and 176 broader Windows regressions PASS**, plus real OS process-crash checks, EXE compile, duplicate-launch and restart smoke. These groups overlap and are not summed. Android unsigned review APK, Web build, backend 268, OAuth 14 and Firestore rules 25 checks PASS. The workflow's embedded cloud job is skipped by branch condition and supplies no live evidence.

Separate push-triggered workflows: [real TEST cloud 38070710562](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38070710562), [disaster acceptance 38070710623](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38070710623), and [platform push 38070710549](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38070710549). The connector commit-workflow listing filters PR runs, so it must not be treated as a complete push-workflow inventory.

The first real-cloud attempt stopped before pairing at the runtime-provenance fence with zero checks; the TEST service still ran `0a3a4ea`. Disaster acceptance correctly stopped at failed cloud evidence with zero recovery checks/writes. Only existing TEST service `saarthi-sync-v2-test` was deployed (auto-deploy off): `dep-db576inlot8c73dv4rhg` went live at **3376738**, 17:18:43.322 UTC, and read-only health verified that exact commit. No production service or deployment configuration changed. The failed cloud prerequisite was then rerun; its final outcome and subsequent disaster rerun still require checking before any new live PASS claim.

Local OAuth regression after installing declared dependencies: **14 PASS / 0 FAIL**. The initial attempt without the broker dependency directory had 13 PASS / 1 FAIL (missing modular Admin SDK), not an authentication regression.

A follow-up UI refinement filters cached download observations by the currently active school before rendering, covering the interval before a new profile refresh finishes. A widget regression verifies that another school's counts never render. This UI-only refinement does not change the tested sync engine, backend or TEST runtime; its own exact-commit platform check must pass. The capacity acceptance plan is in `docs/smart-sync-3-capacity-acceptance.md`; no live load exercise was executed.


### Follow-up UI verification

Application/UI commit `a7396ace8eb457917ebc5015f7b4910940eb127f`: [exact-commit platform PR run 38071583436](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38071583436) completed with **all five platform jobs PASS**. Windows logs: **25 SQLite tests, 97 production SQLite recovery/screen/queue/startup tests, 177 broader regressions PASS**, including rejection of a previously active school's cached download observations. Groups overlap; do not sum them. Windows compile, duplicate-launch and restart smoke PASS; Android review APK, Web, backend, OAuth and Firestore security PASS. No new sync-engine/backend changes occurred after `3376738`; TEST runtime and its live chain remain tied to that exact engine commit.

### Exact next implementation steps

1. Clean-install activation: authenticate/re-authenticate the central school account first; validate the sealed backup's actual SQLite/JSON profile identity and every school-scoped record, deletion and pending intent against that school. Reject mixed/foreign/unbound identities unless an explicit verified migration exists. Verification must not open and modify the sealed source database. Work only in a separate destination; preserve original file bytes and an audited mapping from original references to the new cache. Compare record/file hashes, original operation IDs, capture times and revisions. Add an explicit administrator activation gate, a resumable activation journal and an atomic storage-pointer switch only for an isolated fresh install. Reject nonempty/newer existing storage instead of merging or clearing it. The existing resumable copy helper is preparation, not authorization for that switch.
2. Offline Recycle Bin: preserve `_windows_local_deletions` and original pending delete intents. Add authenticated administrator review and an atomic, school-bound restore request. Define the delete-in-flight/ACK-before-restore ordering and protect the local restored view from stale tombstone pulls. Do not convert a restore click into a guessed ACK, replace the pending deletion's identity, or bypass the server's protected financial restore protocol. Test restart, stale revisions, duplicates and independent pending edits before enabling the control. Prove actual elapsed 24-hour expiry separately; synthetic clock tests and trigger registration alone are insufficient.
3. Binary downloads: obtain a bounded authoritative file inventory, persist expected content hashes and explicit pending/failed/interrupted states, stream into a temporary file, verify bytes and commit the cache atomically before recording successful local readback. Keep missing/partial inventory Unknown/Partial. Record inventories currently certify metadata only and cannot certify a photo/PDF cache.
4. Keep original-school request `7a8e0438-cc6c-443b-947b-14f7eb68f86f` read-only. A fresh Render log query confirms `managed/records`, HTTP 502, `SCRIPT_OPERATION_FAILED` at 2026-10-09T14:59:01.439910428Z. The correlated request log also reports 502. Neither log contains the underlying Apps Script exception or source line; those require original-school execution diagnostics. The previously reported one fee/two document intents were not replayed, cleared or changed by this session.
5. Use the capacity plan before proposing live load. Use isolated device procedures above for physical Windows minimized/full-hour/sleep/wake/Wi-Fi and physical Android restart/airplane-mode acceptance. Current host/emulator evidence must stay explicitly labelled.


### Retained offline snapshot inventory

Recycle Bin now reads retained `_windows_local_deletions` before the cloud inventory, with bounded local reads and school/category validation. Local snapshot names, device deletion time and stored deletion-receipt linkage remain visible when the cloud is unavailable. Foreign snapshots are not rendered; changing category clears the old inventory. This is a read-only recovery inventory, **not offline restore activation** and not proof of a current server expiry window. Financial evidence, file bytes and original pending delete identities remain untouched. A widget regression uses stored snapshots and verifies unavailable-cloud visibility, foreign-row exclusion and unchanged pending deletion/hidden record. Exact-commit hosted verification is required for this UI extension.
