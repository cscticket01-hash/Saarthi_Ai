# Vidya Saarthi finalization report — 11 October 2026

Overall verdict: **PARTIAL**. Shared Sync source changes are implemented in Draft PR24. Live deployment, physical acceptance and the dependent ID/QR2.0 upgrade are not complete. No completion percentage is claimed.

Draft: https://github.com/cscticket01-hash/Saarthi_Ai/pull/24 . Branch: `feature/smart-sync-3-finalization`. Main remains the pre-existing PR23 merge `285b8585af012d3f565446a9d2f9637f3e71ac60`; this work has not merged or deployed to production. Original one fee and two document pending operations were not replayed, overwritten, cleared or force-acknowledged.

## A. Smart Sync requirements

“Implemented” describes source behavior, not live or physical acceptance. Automated test results are recorded separately below.

| # | Requirement | Implemented source | Automated evidence | Live TEST / physical | Remaining |
|---|---|---|---|---|---|
| 1 | Recycle Bin | School/category/deletion/deadline/known actor/ACK eligibility; protected restore; permanent deletion disabled with explicit protocol reason | Node retention/restore/slot tests PASS; Hosted Flutter regression CI PASS (d6791507) | UNVERIFIED | Real retained-day expiry and owner-approved permanent deletion policy; no destructive endpoint invented |
| 2 | Sidebar controls | Recovery, measured status, storage and diagnostics moved into sidebar/drawer | Hosted Flutter regression CI PASS (d6791507) | UNVERIFIED | Device layout acceptance |
| 3 | PC/Drive storage | Actual local Windows volume used/total/free; 3s bounded native measurement, cache; separate app bytes and partial school Drive measurements | Native seam/cache/timeout/late-result tests PASS; real Windows API physical acceptance remains | UNVERIFIED | Real PC/account quota acceptance; unknown quota remains Unknown |
| 4 | Combined pending | One total; failed/conflict/attention are subsets, including legacy queue entries | Hosted Flutter regression CI PASS (d6791507) | UNVERIFIED | Actual multi-queue UI acceptance |
| 5 | Safe Sync/Pause | Stop new request admission; accepted request finishes its real ACK; newer edits remain queued; Pause stays usable during manual Sync | Hosted deferred-request and queue regressions PASS | UNVERIFIED | In-flight physical Windows acceptance |
| 6 | Clean Overview | Removed duplicate heavy diagnostics; detailed views remain navigable | Hosted Flutter regression CI PASS (d6791507) | UNVERIFIED | Real layout check |
| 7 | Local organization | Existing tenant-scoped SQLite/files, backups and migration retained; no data reset or destructive reorganization | Independent queue/migration tests PASS | UNVERIFIED | Existing installation/process/device recovery |
| 8 | Activity / repair | Measured request/ACK/retry/conflict/authorization stages with stable IDs; exact-own-operation transient retry in serialized engine lane | Hosted activity/retry regressions PASS | UNVERIFIED | Real runtime errors; conflicts never get blind repair |
| 9 | LIVE UI removal | Header removed; actual queue evidence remains | Hosted Flutter regression CI PASS (d6791507) | UNVERIFIED | Physical UI check |
| 10 | Event + hourly sync | Durable mutation wake; ordinary four-minute reads no longer advance full-audit checkpoint; restart/sleep deadline derived from persisted checkpoint; durable row backoff with no unrelated-record starvation | Hosted timer/backoff regressions PASS | UNVERIFIED | Fresh actual elapsed-hour/restart/sleep/wake run required after meaningful scheduler change |
| 11 | Universal / Import Sheet | Canonical/generated bundle2026-10-11.1; dedicated school-root versioned Sheet, consent, preview/read/commit UI; raw-source fingerprint, encrypted actor/school/30min plans,20 fixed slots, CAS/readback; atomic student slot guard including restore | Focused import/device/planner35/35 PASS; independent import/storage47/47 PASS | BLOCKED | Real schoolA/B deployments and explicit TEST rollout; imports default disabled |
| 12 | Five-PC authorization | Transactional cap5, secure per-account PC credentials, every protected request checked; fresh login for new/revoked authorization; list/revoke UI; signed school/user/device/generation-bound15min offline lease; sticky enforcement rejects downgrade | Device tests included above; Node/Dart compatibility fixture; Hosted Flutter regression CI PASS (d6791507) | BLOCKED | TEST signing key/public pin and enforced real-PC acceptance; default disabled |
| 13 | Timed pause | Device-local durable1/12/24h menu, maximum24h; restart/expiry; explicit resume persisted before admission | UTC instant assertion fixed; hosted pause regressions PASS | UNVERIFIED | Physical restart and actual expiry |
| 14 | Android / notices | APK header/body/idle time bounded with temporary-only cleanup/hash; dashboard content+verification time one commit; cache-write failure distinguished from server timeout; stale error prevention; existing durable notice IDs/ACK path retained | Android compatibility/dashboard57/57 and APK build PASS | UNVERIFIED | Original operation/provider traces, actual Windows notice completion and Android independent operation |

## Implemented safety and failure behavior

Malformed legacy requests are retained for review. Duplicate-student or generic “already deleted/not found” text no longer guesses an ACK or deletes the pending original. An actual successful legacy response rereads the queued body before removal. Document/record retries preserve IDs, payloads and timestamps, and accepted ACKs never overwrite newer local edits. Observer errors cannot change queue integrity.

Temporary transport, timeout and server failures receive typed delayed retry. Authorization, configuration, unknown failures and conflicts require diagnosis/review. Contextual repair rereads current school/profile, operation ID, queue state and failure category; it cannot acknowledge a conflict or send a foreign school operation. Legacy records lacking typed repair eligibility do not receive a speculative retry button.

Device secrets are generated securely and saved before registration; only exact HTTPS central endpoints receive them. A stable install identity has separate endpoint/Firebase-account credentials. Revocation rotation affects only that account. Server signatures cover the base64url payload segment and use `version:1`; client fixtures match the actual server generation hash. Missing public pin or invalid/expired lease fails closed in enforced mode. Immediate offline revocation cannot be proved; the signed15min ceiling bounds it. Online requests, presence and storage ticket redemption recheck current registry proof.

Revocation filters are fixed-size append-only metadata: safe false positives reject a credential; no removed credential becomes active again. The former1,000-history admission cliff is removed. No registry or import was activated against live school records.

Import source is one explicitly bound workbook, not arbitrary school/internal Sheets. Headers, root ancestry, school marker, version and100-row maximum are verified. Commit rereads the source and rejects edits after preview. New/changed class/section/roll slots and recycle restoration run under the existing ScriptLock. Unrelated legacy rows remain intact with partial-scope warnings; tombstones do not resurrect students. Stable operation IDs and exact readback reconcile lost ACKs without duplicate writes. Twenty encrypted preview slots bound storage; expired metadata slots may be reused, never school records deleted.

## B. ID Card Engine2.0

The shared Sync acceptance gate is **PARTIAL**, so the ID/QR integration branch has not been activated. Pre-gate inventory/design is complete; this is not implementation completion.

| Feature | Verdict | Existing foundation / remaining |
|---|---|---|
| Smart photo positioning | PARTIAL | Focus crop/bounds and original preservation exist; face detection, manual adjustment UI and representative preview remain |
| Drag/resize designer | BLOCKED | Current template selection is not a designer; undo/redo, guides, front/back editing and immutable historical versions remain |
| Class bulk generation | BLOCKED | Current serial changed-card publication is not class bulk;50/100/500 resumable manifests and measured outputs remain |
| Professional print | PARTIAL | Existing PDF renderer; planned concrete A4 portrait9/landscape8 geometry; duplex/calibration/cut marks and physical printer remain |
| Multilingual cards | UNVERIFIED | Embedded fonts do not establish Bengali/Hindi/Assamese shaping or readable final PDFs |
| Academic session cards | BLOCKED | Shared immutable cardIssue/session lifecycle and administrator bulk approval remain; student promotion is never inferred |
| Digital cards | PARTIAL | Existing authorized Android view; issue validity/revocation-aware cache and shared printed identity lifecycle remain |

Local preparation commit `3fa874f`, branch `feature/id2-contract-preparation`, documents seven gaps, exact ownership, geometry vectors and final-PDF verification requirements. It is not integrated or published. Existing single-card checks cannot certify every card of a bulk PDF.

## C. QR Engine2.0

| Feature | Verdict | Existing foundation / remaining |
|---|---|---|
| Fast scanner | PARTIAL | Existing camera and duplicate suppression; quality/low-light/autofocus/device measurements remain |
| Windows / Android compatibility | PARTIAL | Shared v2/VS3 parser preserved; server issue identity adapter and actual upgrade acceptance remain |
| Advanced security | PARTIAL | School/token/session checks; per-card lifecycle, challenge/replay policy and safe audits remain |
| Lost / revoke / reissue | BLOCKED | Inactive pure revision/idempotency planner prepared; authoritative transaction, UI and history not integrated |
| Smart attendance | PARTIAL | Existing calendar/geofence/accuracy/duplicate handling; time-limited challenge and card issue checks remain |
| Offline attendance | PARTIAL | Existing durable owner-scoped SQLite and signed15min permit; capture-device/cardIssue binding across restart remains |
| Bulk QR | BLOCKED |100–500 deterministic mapping, missing-data report and resume remain |
| Final-output QR quality | PARTIAL | Existing300DPI verifier; all-card/intended-person equality/multi-resolution and physical scans remain |
| Security dashboard | BLOCKED | School-scoped measured verification/revocation counters remain; unknown is not zero |

Local preparation commit `8c6d473`, branch `feature/qr2-lifecycle-scaffold`, pure inactive planner tests7/7 PASS. No new card was issued, existing QR replaced, or lifecycle source integrated. Shared schema keeps school/student identity, cardIssueId, protocol2/3, validity, session, status, revision and stable operation ID; Unknown offline never means Verified Active.

## D. Bugs and evidence limits

| Finding | Cause / change | Evidence and verdict |
|---|---|---|
| Legacy queue removed without ACK | Malformed deletion and duplicate/notfound inference | Confirmed source defects corrected; hosted regression PASS |
| Pause disabled during manual Sync | Shared long-running busy guard | Corrected; hosted deferred-request regression PASS |
| Hourly inventory indefinitely postponed | Four-minute delta read advanced audit checkpoint | Corrected persisted deadline and separate poll/audit; fresh elapsed-hour run required |
| Enforced offline access failed | Client/server version, signed bytes and generation differed | Corrected actual protocol; Node-generated compatible fixture verified |
| Enforcement downgrade reused72h cache | In-memory identity not refreshed/sticky | Independent finding fixed; downgrade rejected and regression added |
| Android cache timeout looked like server failure | Two writes and partial in-memory mutation after actual successful response | One verified commit, rollback and typed local cache failure; original screenshot cause still UNVERIFIED |
| Android update download stalled | Network stream lacked full bounds | Header/idle/body limits; preserve previous APK and clean only temporary file; local finalization is not absolute end-to-end deadline |
| Windows Notice spinner | Historic UI/runtime not reproduced; source locally commits stable notice then schedules cloud | UNVERIFIED original operation/provider ACK trace; no duplicate retry assumption |
| Original school502 | Actual Apps Script exception unknown | BLOCKED owner-authorized execution diagnostics; original pending fee/documents untouched |
| Recycle Bin buttons overflowed | Vertical actions were constrained to ListTile trailing height | Natural-height content and wrapping actions corrected; hosted layout regressions PASS |
| Windows disk probe never completed | Cleanup callback returned its own completing Future | Confirmed cyclic completion fixed by void cleanup; cache/in-flight/timeout/late-result and widget regressions PASS |
| Import partial/lost ACK lost retry plan | UI discarded preview on any successful HTTP response | Original plan retained until matching fully verified result; explicit expired re-preview; hosted widget regressions PASS |
| First hosted review failures | UTC/local DateTime equality, missing legacy backoff parameter, synthetic error before request listener | Corrected without weakening expiry or retaining-data checks; latest corrected source CI PASS |

## E. Commits, tests and deployment

Reviewed source coordinator commit `85289fb2a4665ebdb995bc3e31745d58ae8ca81f` maps to remote reviewed tree `f72a5bc46efa9bf42300bc494041716c48c8a58e`, remote commit `b88c7885feee7725cc60e06f4e172b41eacfe4cc`. Follow-up exact-source candidate `6b306ce1ac85b335164a96ce4feba1fe6c4a42b9` maps to tree `69bcfa21812bd2fc513e16e3cc0ceca9e05e377d`.

Reviewed corrected source candidate: `d6791507ee2823ae18666a65e0e3eacfc30a1204`, tree `ab2e38b9e43bd82c487295f3fbe645c9947a55b3`; Exact-source run https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38124355168: **All six jobs PASS**: backend, school-security, web, Android, Windows and isolated read-only cloud. Windows groups passed25 SQLite integrity/API,178 production queue/activity/pause/import/storage,2 compiled OAuth,189 ID/startup/regressions,3 manifest,16 documents,1 reference PDF test. Real OS crash recovery and controlled local benchmark passed; release EXE compiled and hosted launch/duplicate-launch/restart smoke passed. These groups overlap and are not summed. Hosted Defender step success alone is not physical-PC antivirus acceptance. Android compatibility/dashboard group57/57 and debug APK build PASS. Web regression groups passed115,16,29,15,142 (one Windows-only process-lock test skipped on Linux),15 and57 respectively; no overlapping totals inferred. New import retry/identity and Recycle Bin regressions passed in the142-test group. Intermediate c71b07b run38124202763 caught a coordinator-added Windows path literal escape compile error. That edit was fully reverted; source restored to the independently reviewed0c63bae behavior. Backend/security/read-only TEST checks in that run passed. Previous candidate `9294149dc80a20167b52dd17e2e69f0dc63f1a0a` platform run: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38123571771 . It completed with backend, school-security, isolated read-only cloud and Android PASS; web and Windows FAIL. Windows SQLite integrity group passed25/25. Failures exposed Recycle Bin layout overflow, disk-probe cyclic future cleanup and pending native timers in widget fixtures, fake one-shot timer lifecycle, and legacy outage fixtures classified as unknown. These failures were corrected and the new import retry group subsequently passed in d6791507 run38124355168. Previous run38123115892 backend/security PASS; web missing-parameter and Android synthetic-test timing FAIL, corrected in the latest candidate. Earlier35cbbb run38121932589 Windows150/151 tests PASS with UTC representation mismatch; corrected. Skipped isolated-cloud jobs never counted as live acceptance.

Local Flutter/Dart unavailable. Focused Node35/35 and TEST configuration8/8 PASS. Independent final reviewed full backend:325 PASS, one suite failed to load `firebase-admin/app` in scratch; latest configured hosted d6791507 run passed331/331 backend, runtime identity2/2 and OAuth14/14. Latest read-only live prerequisites passed10 checks. Signed health evidence reports runtime `ede88c1d44de5345ac43c3d5e8f8707adeb9e2ea` and deployed Apps Script bundle `2026-10-10.3`, which does **not** match reviewed canonical `2026-10-11.1`. Import Sheet and student-slot uniqueness capability versions remain Unknown. This proves existing service readiness, not new draft deployment or import/device acceptance. Overlapping focused runs are not summed. Independent final source review found no remaining confirmed blocking finding through local0c63bae (restored by e8be6c7) / remote d6791507. Import previews now clear on school/profile/UID/endpoint change and delayed responses are discarded. Full14 live/physical acceptance remains PARTIAL; exact-source CI is recorded separately.

Worker source commits retained in coordinator history: device `bb6a645`, `6b0b2f6`; import `9ac4b11`; UI `8cc2551`; scheduler/activity `6ff92a9`, `1329380`, `4a1e782`, `27f1f93`, `0858c76`, `78b43f6`; Windows import retry/isolation `d700187`, `f47dce1`; disk completion `7490e34`; timer lifecycle `53645fa`; Windows accounts `017f8cb`, `2286f45`, `439cd40`, `7216b85`, `80bb4fe`; Android timeout `7f34782`. Coordinator-only integration/publication; isolated worktrees prevented shared-file races.

Existing Render TEST service `saarthi-sync-v2-test` / `srv-db3tgfu7bikc73abm7a0`, auto-deploy disabled, configured branch `feature/smart-sync-3`. Last read-only verified live deploy `dep-db5fu5flot8c73eqt9kg` uses `ede88c1d44de5345ac43c3d5e8f8707adeb9e2ea`, not the latest draft. Triggering that unchanged configuration would deploy the wrong source. No duplicate service created. Source TEST flags fail closed unless isolated school mode and an explicit signing key are configured; default feature flags remain false. Production service was not changed.

## F. Remaining acceptance gates

- **PASS:** exact-source d6791507 Windows, Android, web, backend and security CI; read-only live readiness also PASS. The final report-only revision changes no application/workflow source; tested source SHA above remains the acceptance reference.
- Existing TEST service must target reviewed source; actual canonical Apps Script bundle provenance and real schoolA/B restoration/import/device contracts require authorized owner/service configuration. Source tests are not deployed-script proof. Automatic approval review rejected opening the private Apps Script site for original-school diagnostics because private school/account content could be exposed; no browser access or workaround occurred. Explicit read-only access approval is required for that blocked action.
- New signed TEST device key/public pin and actual five-PC revocation/re-auth/offline expiry; no private key belongs in the app/repository.
- Physical Windows/Android restart, airplane mode, sleep/wake, accepted-request pause/resume, representative document/photo quality and printing/scanning.
- Fresh real elapsed-hour audit acceptance. Retained real-day deadline is **12 October2026 06:35:19.426 IST**. Do not retime, recreate or purge that fixture; it is not yet due during this work.
- Original-school Apps Script502 diagnostics and original one fee/two document resolution; no replay/clear/forced ACK permitted.
- Live capacity25→100→1,000→5,000→15,000 requires verified quota/headroom/fixtures/concurrency/costs; mocked benchmarks do not establish provider capacity, billing must not be enabled.
- Independent shared Sync acceptance before ID/QR2.0 integration, then complete seven ID and nine QR features, separate independent reviews and real final-output/physical acceptance.

Allowed verdicts are PASS, FAIL, PARTIAL, BLOCKED and UNVERIFIED. No main merge, production deployment, public EXE/APK publication, download-link change, billing, destructive migration or school data deletion occurred.
