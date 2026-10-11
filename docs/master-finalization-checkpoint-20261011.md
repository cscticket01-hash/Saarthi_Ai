# Vidya Saarthi finalization checkpoint — 11 October 2026

Baseline main: `285b8585af012d3f565446a9d2f9637f3e71ac60`. PR23 is already merged; historical open/draft instructions must not overwrite it. New work is isolated on `feature/smart-sync-3-finalization`. No main merge, production deploy, release or school data operation is authorized by this assignment.

## Inventory and acceptance

| Requirement | Current status | Remaining |
|---|---|---|
| 1 Recycle Bin | Existing protected restore; PARTIAL | Explicit per-row identity/deadline; safe permanent-delete policy; actual retained-day expiry |
| 2 Sidebar | New cleanup implemented; UNVERIFIED Flutter | Exact-source widget/build CI |
| 3 PC/Drive storage | Existing measured school-folder bytes; PARTIAL | Actual PC used/total; authorized account quota measurements |
| 4 Combined pending | New combined card; UNVERIFIED Flutter | CI; attention/conflict are subsets, never added to total |
| 5 Safe pause | New admission policy; UNVERIFIED Flutter | CI and physical accepted-request/pause/resume |
| 6 Clean Overview | New dedicated diagnostics view; UNVERIFIED Flutter | CI/visual acceptance |
| 7 Local storage | Existing school-scoped SQLite/binaries; PARTIAL acceptance | No destructive reorganization; physical recovery |
| 8 Live contextual repair | Existing activity; PARTIAL | Per-operation measured stage/repair telemetry |
| 9 LIVE UI removal | New UI removal; UNVERIFIED Flutter | CI |
| 10 Automatic sync | Existing durable mutation hooks/hourly scheduler; PARTIAL | Restart/OS sleep/wake/physical acceptance; polling distinction |
| 11 Universal/import | Signed universal source exists; inactive planner/routes10/10 PASS | Sheet preview UI, admin commit, revision recheck, stable ACK/readback |
| 12 Five PCs | Inactive transactional registry foundation7/7 PASS | Server all-action device enforcement; device tokens/revocation/UI/history/offline expiry |
| 13 Timed pause | New local durable 1/12/24h menu; UNVERIFIED Flutter | CI and physical restart/expiry |
| 14 Timeouts/notices | Bounded update download fix; original bugs UNCONFIRMED | Exact deployed Apps Script + operation trace; real school timeout/notice evidence |

## New safety work

Malformed legacy pending requests previously deleted without ACK are now retained for administrator review with original fields/operation IDs. Legacy queue entries become visible in the queue summary. Admission gates stop new records, documents and restore requests, while an already admitted request processes its real ACK normally. Timed pause is device-local and school-profile-bound, with a secure local device marker; resume persistence precedes new admission. Scheduled expiry does not clear pending data.

Android download now bounds response headers and network body/idle waits, cancels failed streams, removes only temporary APK data and verifies a supplied hash. Local close/hash/cancellation tail is not an absolute end-to-end deadline. Historic25s update/spinner cannot be claimed reproduced by current source.

## Ownership and review

UI specialist: control-center/new cleanup tests, then existing navigation tests. Pause specialist: engine, pending queue, new pause policy/tests. Timeout specialist: public update helper, Android update UI/tests. Import specialist: new pure planner/tests only. Coordinator: bridge/restore admission, integration/UI wiring, CI selection/checkpoint. Independent specialist audited new units and found restore-conflict visibility and omitted legacy queue entries; coordinator corrected both. This is limited new-unit independent review, not full Sync acceptance or independent ID/QR release audits.

## ID/QR dependency gate

Existing renderer/focus crop/bounds/font/PDF and QR v2/VS3 compatibility remain preserved. Face detection, designer UI, bulk resume/print plans, multilingual acceptance, issue/revocation lifecycle and device-bound offline capture authorization remain incomplete. Do not create/activate the ID/QR integration branch until stable Sync foundation and independent acceptance. Existing single-card export verification is insufficient for multi-card PDFs; future verifier must decode every card region against a batch manifest.

## Evidence and blockers

Baseline head3406d9 platform38113600621 Windows/Android/Web/backend/security PASS; embedded isolated-cloud job SKIPPED, not live evidence. Latest main merge is identical tree lineage, not a new live cloud claim. New pure preview planner Node4/4 PASS; diff checks PASS. Flutter/Dart unavailable locally; all new Flutter tests remain UNVERIFIED pending hosted CI. No successful historic test rerun unnecessarily.

Original-school502 cause remains unconfirmed; preserve one fee and two document pending operations without replay/clear/force-ACK. Provider high-volume load needs verified quota/headroom/fixtures. Physical Windows/Android, representative photo/PDF/seal/signature, printer scanning and retained real-day fixture deadline12October202606:35:19.426IST remain external acceptance gates. Retained fixture must not be recreated, retimed or purged.

## Further reviewed preparation

The inactive five-PC registry foundation has7/7 Node tests PASS, independently repeated by the reviewer. Protected requests/Windows UI do not yet invoke it: requirement12 remains PARTIAL. Credential tombstones cap admission at1,000 retired credentials per school; production capacity policy remains unresolved. No live registry write occurred.

Inactive controlled import routes have10/10 focused Node tests PASS (six route tests plus four planner tests). The reviewer independently ran the six route tests. They require authenticated school administrator identity, fresh signed records, revision CAS, sealed school/actor/input/expiry-bound plans, stable retry IDs and exact readback. Default studentImportEnabled=false. Concurrent class-roll uniqueness across different students, designated Sheet binding, quota/admission and preview retention remain blockers. Existing snapshots require populated class/section/roll and reject tombstones: safely restrictive, not universal compatibility. No live import occurred.

The independent reviewer found that the first manual-sync UI guard disabled Pause Sync during a manually started request. Follow-up separates the manual-command and short control guards; a deferred request widget test requires pause to remain clickable before completion. That test remains UNVERIFIED pending hosted Flutter CI. Managed retries no longer spin when only legacy protocol requests remain.

## B. ID Card Engine2.0

| Feature | Verdict | Remaining |
|---|---|---|
| Photo positioning | PARTIAL | Face detection, manual UI, representative quality |
| Drag-and-drop designer | UNVERIFIED / not implemented | Editing, undo/redo, historical versions |
| Bulk generation | PARTIAL foundation | Class batch, resume,50/100/500 actual measures |
| Professional printing | PARTIAL | A4/PVC/custom/duplex/cut marks and physical printer |
| Multilingual cards | UNVERIFIED | Bengali/Hindi/Assamese shaping and PDF/readability |
| Academic session cards | UNVERIFIED | Admin issuance lifecycle, historical manifests |
| Digital cards | PARTIAL existing | Card issue expiry/revocation lifecycle |

## C. QR Engine2.0

| Feature | Verdict | Remaining |
|---|---|---|
| Scanner | PARTIAL existing | Actual hardware focus/low-light/quality measurements |
| Windows/Android compatibility | PARTIAL existing | Current upgrade compatibility acceptance |
| Security | PARTIAL existing | Issue lifecycle, challenge/replay/security review |
| Revocation/reissue | UNVERIFIED | Shared cardIssueId and administrator lifecycle |
| Smart attendance | PARTIAL existing | Updated challenge/device policy acceptance |
| Offline attendance | PARTIAL existing | Capture-time device-bound authorization across restart |
| Bulk QR | UNVERIFIED |100–500 mapping and resume |
| Final-output quality | PARTIAL single-card | Every-region decoding against bulk manifest |
| Security dashboard | UNVERIFIED | School-scoped measured issue/security data |

## D. Bugs

| Bug | Cause/fix evidence | Verdict/remaining |
|---|---|---|
| Android school-server timeout |25s client vs possible30s nonce-lock is a hypothesis; not reproduced | UNVERIFIED actual deployed script/request/ACK trace |
| Android App Update timeout | Current checks differ from historic533; unbounded APK stream fixed | PARTIAL; Flutter/network/physical verification pending |
| Windows Notice spinner | Current path durably saves locally then background schedules; historic spinner not reproduced | UNVERIFIED original operation/runtime evidence |
| Original-school502 | SCRIPT_OPERATION_FAILED source exception unknown | BLOCKED owner execution diagnostic; no replay |
| Three original pending conflicts | One fee/two documents untouched | UNVERIFIED resolution; preserve original intents |
| Legacy malformed queue deletion | Confirmed source deletion without ACK; retained needsAttention now | PARTIAL pending Flutter regression |
| Manual Sync Pause disabled | Independent source reproduction found long busy guard; separated | PARTIAL pending deferred-request widget test |

## E/F. GitHub and verdict

PR23 was already merged before this session. New draftPR24: https://github.com/cscticket01-hash/Saarthi_Ai/pull/24 . Integration branchfeature/smart-sync-3-finalization. New ID/QR branch deliberately not created: shared baseline gate incomplete. Coordinator local commits preserve individual worker units; connector commits preserve identical reviewed trees on the draft branch. Main remains285b858 unless a subsequent independent actor changes it; recheck before integration.

Overall verdict: PARTIAL. Hosted exact-source application tests, active device enforcement, complete universal Sheet import, ID/QR2.0 and the listed external/physical acceptance are incomplete. No completion percentage is asserted. Do not merge/deploy/release from this preparation checkpoint.
