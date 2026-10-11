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
