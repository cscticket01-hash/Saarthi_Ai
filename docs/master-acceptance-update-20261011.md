# Retained real-day Recycle Bin acceptance — 12 October 2026

This addendum supersedes the Recycle Bin deadline status below. The retained isolated TEST fixture was checked only after its genuine server deadline; it was not recreated, retimed, purged, rebound or restored while recoverable.

- Result: **PASS (isolated TEST, not physical acceptance)**.
- Guarded workflow: [run 38190801364](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38190801364), job `recycle-live`, exact check source `d15f85198734a96d2b40abe1ce45ec2bdedc7f6e`.
- Artifact: `isolated-test-recycle-readback` ID `11720623590`, digest `sha256:1529c671f7f9cdfd53eb6eccc9dfe2e63f88e825cd306c16ef5ade41ef1f01ae`.
- Fixture: `recycle-expiry-v1-20261011-resume-acceptance`; deleted revision `26d0800c-5f42-4022-bfc2-a959bc5c3c9a`; `deletedAt=1791680719426`; `recoverUntil=1791767119426`.
- Provider-observed `serverNow=1791767398899`; elapsed `86679473 ms`; status `expired`.
- The authenticated expired restore probe was rejected with HTTP 502 / `SCRIPT_OPERATION_FAILED`. The sanitized provider response does not expose the owner-only exception, so no narrower provider reason is claimed.
- Post-probe authenticated readback proved the same Sheets tombstone, Drive snapshot deadline and retained audit were unchanged. `expiredRestoreRejected=true`, `auditRetainedAfterProbe=true`, `fixtureRetained=true`, `permanentDeletion=false`.
- Harness scope tests: **5 passed, 0 failed** before the live probe.

State discovered before this report-only update:

- `feature/smart-sync-3` acceptance source: `d15f85198734a96d2b40abe1ce45ec2bdedc7f6e`.
- TEST Render service `srv-db3tgfu7bikc73abm7a0`: LIVE deploy `dep-db62uftckfvc73bultmg` at runtime `4598fd3560f0610b8b21fe82876592a060b558ba`; auto-deploy remains off.
- PR24 is no longer a draft: it merged at `2026-10-11T16:58:22Z`; its recorded head remains `afd5308991e10c9de7cae6f56812651c18723766`.
- Current main is `cd02207127cc2b6dd360c63bc0661a0bd2d5dbcb` (later PR29 merge). Historical runtime/application `335a21c57e1fe77944897d905631e8785171ff3c` evidence remains valid only for its earlier exact-source runs; it is not claimed as the current TEST runtime.

Still not verified here: canonical Apps Script owner upgrade/live import, five physical PCs, physical Android/printer testing, and complete ID Card 2 / QR 2 real-device acceptance. No production deploy, release, EXE/APK publication or main merge was performed by this acceptance update.

---

# Vidya Saarthi acceptance update — 11 October 2026

Overall: **PARTIAL**. Application source `335a21c57e1fe77944897d905631e8785171ff3c` passes all six exact-source platform jobs in run38129113241, after rerunning only the failed read-only cloud job once the deployment was live. Initial cloud failures occurred during deployment; their reports ended after storage health and did not expose a precise transport cause. That cause remains unconfirmed. The successful rerun proves ten prerequisites against exact runtime335a21c, not canonical script upgrade or import/device rollout.

Main remains285b8585af012d3f565446a9d2f9637f3e71ac60. Draft PR24 remains unmerged. Existing TEST service srv-db3tgfu7bikc73abm7a0 / deploy dep-db5ligqjnfac73atn9tg is LIVE at335a21c; school-cloud health ready and exact runtime verified. Production was not changed.

## A. Smart Sync fourteen requirements

| # | Requirement | Implemented | Automated | Live TEST | Physical | Remaining |
|---|---|---|---|---|---|---|
|1|Recycle Bin|Protected restore; permanent purge disabled|PASS|PARTIAL|UNVERIFIED|Original retained-day fixture due12Oct06:35:19.426IST; no recreation/retime/purge|
|2|Sidebar controls|Yes|PASS|PARTIAL|UNVERIFIED|Actual installation layout/navigation|
|3|PC/Drive storage|Scoped measured values; quota Unknown|PASS|PARTIAL|UNVERIFIED|Physical Windows volume and authorized account quota|
|4|Combined pending|One total with attention/conflict subsets|PASS|PARTIAL|UNVERIFIED|Actual multi-queue user acceptance|
|5|Sync/Pause|Safe admission boundary; accepted ACK retained|PASS|PARTIAL|UNVERIFIED|Physical accepted-request pause/resume|
|6|Clean Overview|Heavy diagnostics moved|PASS|PARTIAL|UNVERIFIED|Actual screen layouts|
|7|Local organization|Existing durable school-scoped storage preserved|PASS|PARTIAL|UNVERIFIED|Original installation recovery; no destructive migration|
|8|Activity/repair|Measured events and exact transient retry|PASS|PARTIAL|UNVERIFIED|Actual error interaction|
|9|Remove LIVE UI|Yes; monitoring retained|PASS|PARTIAL|UNVERIFIED|Physical layout|
|10|Event/hourly sync|Separate durable checkpoint|PASS|PARTIAL|UNVERIFIED|Fresh actual-hour scheduler PASS; physical process restart/sleep/wake remain|
|11|Universal/import|Canonical2026-10-11.1; disabled default|PASS|BLOCKED|UNVERIFIED|Deployed script still2026-10-10.3; actual schoolA/B import/restore|
|12|Five PCs|Scoped proof, cap5, signed15min lease; disabled default|PASS|BLOCKED|UNVERIFIED|TEST signing/public pin and real cap/revoke/reauth/offline expiry|
|13|Timed pause|Device-local1/12/24h durable expiry|PASS|PARTIAL|UNVERIFIED|Actual expiry/restart|
|14|Android/notices|Bounded updates and atomic verified cache|PASS|PARTIAL|UNVERIFIED|Original screenshot/provider traces; physical independent operation|

Fresh elapsed-hour run38126239507 PASS, artifact11698802670, source169949099: unchanged production scheduler on hosted Windows observed3,602.010229seconds total,14 ordinary four-minute rearm events, scheduler recreation after five minutes with the same checkpoint, exactly one due request. This is real elapsed time with no fake clock, but not an actual process restart or physical sleep/wake test. The local attempt lost its process and has no artifact; it is UNVERIFIED, not counted. A later automatic source335a21c hour run is separate; no result inferred.

## B. ID Card2

| Feature | Verdict | Remaining |
|---|---|---|
|Smart photo positioning|PARTIAL|Face detection/manual adjustment/representative preview|
|Drag/resize designer|BLOCKED|Shared gate; front/back editor, versioned undo/redo/guides|
|Bulk50/100/500|BLOCKED|Actual app class export/resume/manifests; synthetic verifier benchmarks are separate|
|Professional print|PARTIAL|A4 geometry preparation; actual duplex/calibration/printer|
|Multilingual cards|UNVERIFIED|Actual English/Bengali/Hindi/Assamese shaping/final fonts/long names|
|Academic sessions|BLOCKED|Shared issue lifecycle and admin approval; no student promotion inferred|
|Digital cards|PARTIAL|Validity/revocation-aware cache and shared printed identity|

## C. QR2

| Feature | Verdict | Remaining |
|---|---|---|
|Fast camera scanner|PARTIAL|Actual hardware/low-light/quality measurements|
|Windows/Android compatibility|PARTIAL|Existing v2/VS3 preserved; actual lifecycle upgrade acceptance|
|Advanced security|PARTIAL|Per-card lifecycle/challenge/replay and measured audits|
|Lost/revoke/reissue|BLOCKED|Authoritative lifecycle integration after shared gate|
|Smart attendance|PARTIAL|Time-limited challenge/card issue checks|
|Offline attendance|PARTIAL|Capture-device/cardIssue binding and physical restart|
|Bulk100–500|BLOCKED|Actual app mapping/cancel/resume/missing-data reports|
|Final-PDF quality|PARTIAL|Isolated verifier preparation; actual complete app exports/print scans unverified|
|Security dashboard|BLOCKED|Measured school-scoped counters; Unknown not zero|

## D. Confirmed bug and constraints

Real Chromium run38126097957 logged Firebase loginHTTP200, then UnsupportedError before the central request. Shared managed login called Platform.localHostname on web. Source335a21c returns browser metadata without evaluating native hostname in both registration paths; device credentials, token/proof, registry admission and server verification remain unchanged. Two regressions were added. Independent source review found no blocker. Fresh live run38129114291 Windows actual engines and website UI PASS; Android API35 emulator job114441956527 PASS: native SQLite/secure-storage and actual dashboard, both Windows/website notices read, injected offline boundary save18ms, queued record to verified cloud42,708ms. Physical Android remains UNVERIFIED. Downstream native Android -> real TEST cloud -> existing Windows local-store readback job114443649204 PASS. All five live jobs in run38129114291 PASS.

Original Android timeout/screenshots, original Windows notice spinner and original-school502 causes remain unverified without exact original provider traces. Original one fee and two document pending operations remain untouched. Earlier confirmed queue/pause/storage/cache fixes retain their regression evidence.

User explicitly authorized existing TEST Apps Script browser upgrade. This permission persists. Cloud browser redirected to Google sign-in, which returned502/Connection refused; one reload also failed. No script edit, setup execution, rebind, storage creation or migration occurred. This access failure is distinct from the original-school provider502. Prior automatic-review rejection of original private logs remains a separate authorization boundary.

The signed current TEST response still reports bundle2026-10-10.3 and Unknown import/uniqueness capabilities. Import and device rollout remain disabled. Full shared Sync acceptance stays PARTIAL; no ID/QR application activation.

## E. Preparation and continuation

Draft PR25 is isolated preparation. Earlier24cea45e run38126513546 PASS:12 tests and two real synthetic QR cards at three resolutions, plus wrong identity/non-QR rejection. Independent review caught non-QR false-PASS risk; QR-only configuration fixed it.

New synthetic50/100/500 preparation aa96457c and diagnostic17536a98 runs38129760040/38130010681 FAIL: first card at600DPI, zbar exit4;150/300DPI checks completed before failure. Diagnostic artifacts retain the exact synthetic crop. Diagnostic run38130274024 confirmed the unchanged600DPI raster decodes the exact expected identity with an independent QR-only decoder, demonstrating a ZBar limitation. Historical failures remain FAIL. Strict fallback only for ZBar exit4 with empty output uses QR-only ZXing on the original unchanged raster; other errors, wrong identities and multiple symbols fail closed. Missing fallback dependency fails closed. Independent source review PASS;24 local/hosted unit tests PASS. Fresh prep source6eb6244e264b5a3c574b98d3101c02ab1caf56cf, run38130615671: smoke and all three bulk jobs PASS.

| Synthetic cards | Pages | Decode checks | PDF bytes | Total seconds | Fallback count | Fallback seconds |
|---|---|---|---|---|---|---|
|50|6|150|23,226|4.069|18|0.095|
|100|12|300|45,023|4.773|34|0.111|
|500|56|1,500|222,289|21.816|168|0.497|

Each declared QR was decoded at150/300/600DPI and matched exactly one expected identity. These are synthetic single-front fixtures and verifier measurements, not actual application class exports or physical print acceptance. Quiet-zone metadata/provenance and unlisted regions still have stated limitations. In-process ZXing has no per-call timeout;360seconds is a cooperative budget and workflow10minutes is the hard stop. RSS is process-lifetime parent/maximum-child high-water, not simultaneous combined memory.

Coordinator owns source refs, existing TEST deploy and publication. scheduler_acceptance owns real-hour harness; independent_audit performs read-only reviews; idqr_preparation owns isolated verifier/benchmark tools. Worktrees remain separated; no force pushes or shared-file races.

Next: complete canonical Apps Script upgrade when authorized browser access works; real schoolA/B and device contracts; retained-day fixture after its real deadline; physical acceptance; then independent full shared gate before ID/QR integration.

No main merge, production deploy, public EXE/APK/download links, billing, destructive migration, original PC or original-school mutation occurred.
