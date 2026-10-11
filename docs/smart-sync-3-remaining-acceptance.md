> 2026-10-11 continuation: all five platform jobs on 97c2a31193c82982d8434ef4d812fa4ecc1620bd are PASS (run38105746897). Corrected hourly run38105556254 remains running. Fresh bounded binary acceptance is being expanded to 2-5 first-page hashed files, shared-hash-safe repair, disposable missing cache and corrupt-response rejection. Existing synthetic scan originals/high-quality/optimized copies will be retained for visual review; not human readability PASS until inspected. Application/runtime source unchanged.

# Smart Sync 3.0 current acceptance — 2026-10-11 UTC

This checkpoint supersedes the historical pre-integration audit below. Source inspected: `eb6addc9e9c77b1925e98a73487427986ba72c8d`, PR #23 OPEN/DRAFT, 56 commits, 91 changed files. Application/runtime code remains unchanged by the scheduler acceptance correction.

| Area | Code status | Automated test | Real cloud | Physical device | Remaining blocker |
| --- | --- | --- | --- | --- | --- |
| Platform regression | Implemented | Exact-source push [38102879875](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38102879875): Windows/Android/Web/Backend/Security PASS; backend 295, OAuth 14, Firestore 25 | Separate live chain below | UNVERIFIED | New documentation/test commit needs its own CI |
| Hourly scheduler | Production timer unchanged; acceptance uses strict monotonic Stopwatch, UTC diagnostic only | Old [38101196941](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38101196941) FAIL: event 3,600,007 ms, separate wall-clock 3,599,999 ms. Corrected real-hour rerun PENDING | No provider calls by design | UNVERIFIED | Exact corrected-source elapsed-hour result |
| Disaster recovery | Implemented | Five resume tests PASS | [38102879856](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38102879856) nine checks PASS, fresh read-only audit of retained rehearsal: 348/348 rows, 19/19 hashes | UNVERIFIED | Active cutover, local queues and Firebase credentials excluded from cloud rehearsal |
| Recycle restore/expiry | Implemented | [38100482579](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38100482579): restore 11 checks PASS; baseline 2 checks PASS | Restore PASS; real 24-hour expiry PENDING | UNVERIFIED | Same fixture deadline 2026-10-12 01:05:19.426 UTC / 06:35:19.426 IST |
| Windows/Android/Web sync | Implemented | Windows groups 25/143/181 PASS, overlapping; not summed | [38102879867](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38102879867): all five stages PASS, exact source | UNVERIFIED | Physical restart, OS wake/minimized hour, network interruption, printer and QR |
| Central monitoring | Implemented; missing/stale and tenant checks present | Isolation/staleness tests PASS | Actual authenticated hosted Windows report path observed, pending 0 | UNVERIFIED | Report freshness allows ten minutes while backend throttle is five: cannot conclusively exclude recent prior identical report; fleet unknown |
| Binary recovery/quality | Implemented | Corrupt/hash/retry/cache checks PASS | One file verified after injected 503 and restart; inventory PARTIAL | UNVERIFIED | Representative human readability and broader file coverage |
| Attendance capacity | Planning and mocked component benchmarks available | Component evidence only | 1,000/5,000/15,000 real-provider scenarios NOT RUN | UNVERIFIED | Explicit TEST school/workload/quota/concurrency/cost/isolation approval |
| Original-school 502 | Unknown provider exception; pending operations preserved | TEST boundary failure/recovery evidence only | Original cause UNCONFIRMED | Original PC untouched | Owner-only Apps Script diagnostic needs separate authorization |

## Measurements tied to exact historical run

Run 38102879867: Windows local save 15 ms, queue-to-ACK 5,334 ms; Android API 35 emulator offline save 44 ms, queue-to-cloud-read 52,670 ms; Android-to-Windows readback 5,839 ms. These are individual measurements, not throughput guarantees. A deliberately newer TEST Windows edit remains pending and protected.

Fresh disaster verification rereads the retained recovery generation (fixture run 38020985989, attempt 2); it is not a new independent backup generation or an atomic multi-file snapshot. Original fixture row/file revision, operation ID, timestamp and bytes remain protected. Artifact 11689340864 retains the evidence.

## Retained real-day fixture

`recycle-expiry-v1-20261011-resume-acceptance`, deletion `1791680719426`, deadline `1791767119426`, baseline artifact `11688200206`. Do not recreate it, change timestamps, shorten retention or infer real expiry from mocked clocks. At/after the real deadline verify authenticated expiry, rejected restore, retained audit and no unexpected destructive cleanup.

## Expiry acceptance correction

The old check-expiry mode verified inventory expiry but never attempted expired restore. It now issues exactly one authenticated revision-checked rejection probe against only the retained synthetic TEST notice, only after the real server deadline. It requires HTTP 502 / SCRIPT_OPERATION_FAILED, rejects accepted or unrelated errors, then rereads the unchanged full tombstone and retained snapshot audit/deadline. The sanitized provider error does not prove the exact underlying exception; that limitation remains explicit. Before the deadline and in start-expiry resume mode no restore/write/delete/purge is called. Local focused harness/recycle/monitor regressions: 33/33 PASS (5 harness, 17 recycle, 11 monitoring), after correcting the invocation working directory. Real-day PASS remains PENDING.

Continuation checks are scheduled: corrected hourly/platform result after 75 minutes; same-fixture real-day check on 2026-10-12 at 06:36:20 IST. They must inspect actual latest source before acting.

Original-school fresh Render log access is blocked because the connector has no selected workspace and requires user-confirmed workspace ID. No workspace was selected automatically. Historical correlated logs remain evidence only.

## Scheduler failure and correction

The failed assertion was the wall-clock difference at test line 40, not the event's monotonic elapsed bound. UTC event timestamps also place the event before the earlier UTC start despite positive monotonic elapsed, demonstrating inconsistent wall-time measurement. The exact OS clock adjustment/precision mechanism is unconfirmed. Elapsed acceptance now uses monotonic Stopwatch for both the event and post-event strict full-hour bound. UTC timestamps and wall-clock difference are retained as diagnostic evidence. One hourly request, wake/reconnect signals and timer cancellation assertions remain unchanged; no tolerance, clock manipulation, shortened interval or skipped test.

Local Flutter regressions were blocked by automatic approval review because the command attempted cloud instance-metadata access. No bypass was attempted. Local backend initial run had 290 PASS and one file-load failure caused by missing firebase-admin/app dependency; this is not a current-source regression claim. Hosted exact-source CI remains authoritative until local dependencies are available.

## Release gate

BLOCKED pending corrected-source CI/hour result, real-day expiry, physical Windows/Android, representative media quality, scoped provider-load approval and original owner diagnostics. No merge, production deploy, EXE/APK publication, download-link update, billing or original-school mutation authorized.

---

## Historical audit (superseded where current evidence differs)

# Smart Sync 3.0 acceptance audit — 2026-10-11 UTC

Read-only checkpoint: branch HEAD `1647e09835758166adb0eb93fb8372e629417d38`; existing PR #23 OPEN/DRAFT, 46 commits and 69 changed files. This is the pre-integration checkpoint, not certification of subsequent code. PR comments endpoint returned no comments. No successful historical workflow was rerun.

| Evidence | Exact source | Verified result / boundary |
| --- | --- | --- |
| [Platform 38074094184](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38074094184) | `1647e09835758166adb0eb93fb8372e629417d38` | Five platform jobs PASS; backend 268/268, OAuth 14/14, Firestore 25/25. Platform's isolated-cloud job SKIPPED. Unpublished Windows/Android/Web review artifacts; not production releases. |
| [Real TEST cloud 38070710562](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38070710562) attempt 2 | `33767380ad3e5635824cc94808aabdea5184a27d` | Five real-cloud stages PASS: signed prerequisites, production engine classes, Chromium, native Android API 35 emulator and Android-to-Windows readback. Not physical device acceptance. |
| [Disaster 38070710623](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38070710623) attempt 2 | `33767380ad3e5635824cc94808aabdea5184a27d` | Eight checks PASS, separate restored 348 records / 19 binaries; original recovery operation resumed. Active cutover false; local pending queues and Firebase credentials not included. |
| Latest Windows monitoring observation in that disaster run | same runtime | Server durable ACK verified, obsolete failure code absent, Windows report **not observed**. Fleet/client counts remain UNKNOWN. |

The backend log also includes two component benchmark tests; suite groups are not combined into a fabricated unique total. Component fsync benchmarks explicitly use mocked provider delivery: 1,000 / 10,000 / 25,000 / 50,000 submissions were measured, with CPU/RSS and P50/P95/P99 output. These do not establish Google/Firebase throughput or approve live load. Existing [capacity admission plan](smart-sync-3-capacity-acceptance.md) remains mandatory; 1,000/5,000/15,000 provider scenarios need explicit quota/cost/workload approval before execution.

## Monitoring audit

Backend observations and authenticated client reports are separate fields. Reports are school scoped, missing reports are null, optional stale fields are replaced on a new report, and the developer UI labels reports older than ten minutes as stale/current queue unknown. Newly added isolated regression `functions/test/managed-sync-monitor-acceptance.test.js`: **2/2 PASS** locally, covering retained stale timestamp with no invented backend ACK and developer A→B→A selection plus foreign bearer rejection. Hosted CI must verify the final integrated commit. This regression does not create an actual Windows client report or certify a whole fleet. School Drive bytes are authenticated measured summaries; partial inventories remain lower bounds. Media pending counts must not be invented where no authoritative measurement exists.

## Original-school HTTP 502 — read-only correlation

Fresh Render log inspection of existing `saarthi-oauth-staging` re-confirmed:

| Request reference | UTC time | Sanitized outcome |
| --- | --- | --- |
| `070384c9-4da3-444e-8bbf-08b8cac86d73` | `2026-10-09T14:53:50.808274369Z` | `managed/records`, HTTP 502, `SCRIPT_OPERATION_FAILED`; paired `/school-cloud` request 502 |
| `7a8e0438-cc6c-443b-947b-14f7eb68f86f` | `2026-10-09T14:59:01.439910428Z` | same category/endpoint; paired request 502 |

This proves the request reached the central backend. Logs expose no underlying Apps Script exception, diagnostic category/source line or execution stage. Owner-only `VS_readLastSyncDiagnostic()` exists but was not executed against the original school; connected Render/GitHub tools cannot provide that owner execution diagnostic. The exact original exception remains **UNCONFIRMED**. Separate TEST lock/restore failures must not be assigned to this incident. Safe client-boundary 502 regression and real TEST recovery evidence test retry/retention, not a reproduction of the unknown owner exception. One original fee and two document pending operations remain untouched: no replay, original database access, deletion, overwrite, queue clear or forced ACK.

## Acceptance that cannot be inferred

Actual elapsed 24-hour expiry has no retained before/after evidence for the same unaltered TEST deletion in the inspected successful runs. A scheduled empty audit or simulated-clock test is insufficient. Physical sleep/wake, minimized 60-minute operation, Wi-Fi/airplane-mode and actual Android process restart remain UNVERIFIED. Representative photo/seal/signature/fine-print/handwriting/multipage PDF visual quality remains UNVERIFIED. Follow the precise [device acceptance procedure](smart-sync-3-device-acceptance.md). No clocks were faked and no destructive cleanup was enabled.

Release readiness remains **BLOCKED** until the three coding workstreams are integrated and final exact-source CI passes, supported live runtime acceptance is refreshed where changed, and outstanding hardware/media/elapsed-time/provider-budget/owner-diagnostic gates are addressed. No production deploy, merge, publication, billing change or original-school mutation is part of this audit.
