# ID Card / QR2 draft implementation — 11 October 2026

Overall PARTIAL. This is implementation on an isolated draft branch, not live engine activation. Existing TEST runtime remains335a21c and deployed AppsScript remains2026-10-10.3; Google sign-in502 prevents upgrade. Main unchanged.

## Implemented draft changes

- School-scoped front/back designer screen: move/resize, photo focus, snap, validation, undo/redo, immutable draft snapshots and async save callback with visible failure. No persistent repository/route activation yet; no automatic face detection claim.
- Existing PDF renderer reused for bounded A4 class selection up to500: front/back imposition, explicit mirror mode, identity-checked existingQR, immutable data/assets/template, selection fingerprint, progress/cancellation without partial export. Resume checks fingerprint then rerenders the whole selection; no durable checkpoint skip claim.
- QR2 issue lifecycle planner: explicitadmin transition requirement, immutable issue/revoke/reissue history and exact operation replay/conflict checks; expiry and unknown offline revocation fail closed for admission. This planner is not authoritative server authorization or a signed durable registry.
- Universal Apps Script2026-10-11.2: identical unbound source, ownerScriptProperties for school/explicitnewstorageconsent; verifiedexistingroot/secret preserved; trustedcentralendpointallowlist, isolatedTESTschoolguard, no secret-bearingredirects. Generic distributioncopiescanonicalbytes unchanged with provenance.
- Independent every-declared-QR finalPDF verifier at150/300/600DPI and geometry inventory. ExplicitnonQrPages only declare absence; they are geometrychecked, not provenfreeofQR. Inventoryprovenance remains outside decoderproof.

## Evidence

Local92focusedbackend/25verifier/4package/4upgrade tests PASS; standaloneDart designer/lifecycle safety PASS and analysis PASS. Fullbackendlocal331/332: singlemissingfirebase-admindependency, not a verifiedsourcefailure. Hosted workflow installs dependencies.

Initial exactsourcec78dc8152fbe50945cd70a6af9c44f0736469e8c run38132266107: sourceanalysis PASS;34Fluttertests PASS,1immutabilityfixture FAIL(missingrequiredschoolName). Actualrenderer50/100/500exports PASS; samefixture corrected in4e9bed8ee06fad44436f3b71923e74610d661369. Initialfailure remains recorded; fresh exact-source4e9bed8ee06fad44436f3b71923e74610d661369 run38132396365 PASS: source analysis,35 Flutter tests,336 dependency-installed backend tests,25 verifier tests,4 package/4 upgrade tests, both standalone safety suites. Independent actual-renderer QR checks PASS for50/100/500:150/300/1500 exact-payload original-raster checks. Artifacts11700005470 (renderer/decoder) and11699158354 (universal package).

| Latest real renderer synthetic selection | PDF pages | PDF bytes | Render ms |
|---|---|---|---|
|50|12|47,855|237|
|100|24|88,603|263|
|500|112|444,940|1,124|

These are actual draft Dart renderer outputs with synthetic records, not a completed schoolUIbatch or physicalprint. Final PDF geometry and every declared QR decoded at150/300/600 DPI PASS on fresh outputs. Timing is renderer wall time only, not full UI/storage/print latency. Explicit non-QR pages are declared, not independently proven free of QR; full inventory provenance and physical scans remain UNVERIFIED.

## Outstanding completion gates

Persisted designer/versionhistory and realUIrouting, durableclassjobresume/storage/cancel, missing-data reporting, professionalprint calibration/cropmarks, face positioning, rights-cleared Indicfont/shaping and native-readerreview, authoritativecardissue/revocation/signature/dashboard and offlinepermit/device integration remain unfinished. Existingofflineattendanceworker/legacyQRmust be reused and preserved. No localplannerboolean may replace serveradminproof.

Live universalupgrade and signedhealth, real SchoolA/B import/isolation and fivePC registration/revoke/offlineexpiry tests remain blocked by actualaccess/configuration; do not enable flags on oldbundle. PhysicalPC/mobile/printer unverified. Retaineddayfixture unchanged:12October06:35:19.426IST deadline; sameautomation06:36:20IST guardedrejectionprobe, no purge/recreation. Supporteddispatchmust be checked at execution.

DraftPR26 is reviewableimplementation; no mainmerge, TEST/productiondeploy, release/downloadlinks/billing or originalpendingoperation changes.


## Follow-up: safe draft persistence foundation (same draft PR)

- Implemented isolated `lib/id_card_draft_storage_io.dart` with school-hashed filenames, school-scoped manifest validation, SHA-256 accidental-corruption detection, bounded JSON, an OS file lock, flushed temporary writes and rename commit. Existing valid revision is retained as a separate backup when replaced. It never deletes data or calls the cloud. JSON remains plaintext and its hash is **not** an authentication signature.
- `loadDraft` refuses corrupt current data instead of silently taking an older revision. `readPreviousRevision` offers explicit read-only recovery; actual in-app recovery UI and automatic migration are not implemented.
- Designer screen now accepts a stable caller-supplied `templateVersion` instead of incorrectly recording current wall time as the schema version. Existing `onSave` callback can use `IdCardDraftStorageIo.saveDraft` when a real trusted per-school application storage directory and verified school context are supplied.
- Added six targeted regression tests for restart, tenant isolation, prior revision, invalid save retention, corrupted current data and concurrent save atomicity. Wired them into the isolated ID/QR review workflow.
- Historical red CI on commit `05d7515`: 35 existing tests PASS and six added tests FAIL due to an incomplete synthetic fixture missing a required back region; corrected in `15610ced`. Dart analysis and the Flutter regression step PASSED on `15610ced`. Latest application source `ebb140c2` passed all steps of CI run `38134027527` (source analysis, Flutter regression suite including six storage tests, actual-renderer QR decoder, designer/lifecycle suites, backend and universal package/upgrade safety). Evidence artifacts: PDF `11699987793`, Apps Script `11700032676`. The later report-only commit does not change runtime code.
- **Still partial:** No production screen/route activation, existing-school storage path selection, real Windows PC restart, encrypted-at-rest storage, durable bulk-job resume, server-issued QR lifecycle, Indic font shaping, Google Script upgrade or device/printer acceptance. No main merge or deployment performed.

Final isolated review checkpoint: exact runtime/test commit `d1ef3400bdd8a9320930cd3e8e515f65749db3a4` — GitHub Actions `38134205361` SUCCESS. Dart analysis, **42 Flutter tests PASS**, final-PDF verifier 50/100/500 synthetic student exports PASS with 150/300/1500 exact declared-QR checks at 150/300/600 DPI, standalone designer/QR planner, all backend tests, package/upgrade safety PASS. Artifacts `11699888245` (PDF proof) and `11699904888` (universal source). Do not interpret as production or physical acceptance.
