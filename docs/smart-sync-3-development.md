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
