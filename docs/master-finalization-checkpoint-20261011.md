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
| 11 Universal/import | Signed universal source exists; inactive preview planner 4/4 PASS | Sheet preview UI, admin commit, revision recheck, stable ACK/readback |
| 12 Five PCs | Missing device registry/authorization | Server all-action device enforcement; device tokens/revocation/UI/history/offline expiry |
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
