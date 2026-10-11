# VIDYA SAARTHI — Six Requested Completion Gates — 11 October 2026

Status: **PARTIAL, NOT PRODUCTION-READY**. This report distinguishes code, isolated automation, physical acceptance and deployed state. It is not a claim that six outcomes are complete. The change set remains exclusively on draft PR #26 `feature/smart-id-qr-engine-2`, based on draft PR #24. Neither `main` nor owner-school data, billing or deployments were changed.

## 1. Windows designer routing and persistence

**Implemented in draft code**: `lib/windows_id_card_designer_entry.dart` connects the real `SchoolDocumentTemplatesScreen` route in `windows_document_templates.dart` to the existing ID designer. Active school/profile validation precedes/follows async file operations, and draft reopen is backed by local application-support storage. Bundled template catalog validation avoids arbitrary path entry. The operator opens student ID templates and selects **Edit ID design (local draft)**. This is deliberately a draft editor. It does not immediately override current school print templates. Stored designer revisions are raw file-backed JSON with SHA-256 integrity and revision backups, not encryption, server signatures or authorized user audit history.

**Not fully accepted**: Real school routing, authorized on-device folder ACL, PC restart, draft-to-production print promotion and real admin/device acceptance.

## 2. Durable class bulk job resume

**Implemented in isolated code**: Immutable selected identities/photos/QR/template are snapshotted in `IdCardBulkPlan.durableSnapshot` and `IdCardBulkJobStore`; jobs are school-scoped, fail closed on fingerprint drift, and survive process restart with pending journals. They re-render the exact stored selection after interruption; incomplete PDFs are not offered as committed exports. Completed PDFs have verified SHA-256 readback, with old files retained for operator inspection, plus same-process serialization and OS locking.

**Not fully accepted**: An existing school bulk UI is not hooked to this store; incremental resume from last completed PDF page is not implemented (rerenders all selected cards); sensitive snapshots are plaintext and need protected application storage/encryption before wide rollout; process-kill crash acceptance on original PC and actual printer duplex calibration are pending.

## 3. Automatic face positioning and Indic language output

**Partially implemented**: Bengali/Assamese/Devanagari text in the PDF renderer is shaped by Flutter/Skia TextPainter then rasterized to PNG; Latin text remains searchable PDF text. Flutter tests exercise scripts and synthetic generated PDFs; font selection uses installed OS fallback fonts. Existing manually adjustable photo focus/crop controls remain.

**Not implemented**: Reliable face detection/face-center positioning. No new machine vision inference or on-device classifier was added. Fonts are not yet bundled and independently licensed/validated for all deployment hardware; optical quality/native readers/physical print remain unverified. Do not call these complete.

## 4. Authoritative QR issue/revoke/reissue

**Implemented as server draft**: `functions/managed-card-issue-authority.js` proposes transactionally versioned, scoped, auditable issue/revoke/reissue/status/verify registry; `functions/managed-schools.js` integrates behind `cardIssueEnabled=false` and existing authenticated membership, licence and device authorization. New issuance/reissue reads a verified actual person from school-managed script; emergency revoke works without a working script. Replay conflicts and cross-school checks covered by Node tests.

**Not fully accepted**: Feature deliberately DISABLED by default. Old printed card QR format and Android/Windows reader do not yet carry/validate the new card issue ID or signed offline revocation proof. Enabling this now could give a false sense of revocation security. Current physical/offline attendance admission remains on existing safeguards.

## 5. Original school 502 and Apps Script upgrade

**Implemented in reviewed source only**: Sanitized owner-only diagnostic provenance (category, phase, numeric source line, time), retained for at most 24h via owner script properties to avoid anonymous web-app and owner-editor cache mismatch. Canonical and adapter source synced; reviewed scriptBundleVersion `2026-10-11.3`; source packaging and backend regressions run on CI. Neither exception contents nor school secrets are logged. Original school `SCRIPT_OPERATION_FAILED` root cause is not proved fixed.

**Not completed**: Actual Google owner sign-in/script editor access was previously HTTP 502/refused. Deployed school script remains last independently reported `2026-10-10.3` until a signed owner-side health check proves otherwise. No source was applied to original school; no forced migration, setup, purge, or school rebind. To complete: owner-accessible current Script deployment and sanitized fresh diagnostic, then exact bundle and data-preserving health/rollback verification.

## 6. Real Windows, Android and printer tests

**Automated results**: GitHub hosted Windows exact-commit build/review and Linux Flutter/backend/PDF suites are **not** real physical PC/Android/printer acceptance. On a prior exact source commit `a594bc5f4389bba5eb86af6e220bfee2cdf3da16`, both Linux and Windows jobs succeeded in Actions run `38135506374`; newer combined code requires exact-head outcome from run `38135862862` (source `d40eee20499a3988c97e734ade30fe6596068402`). Linux draft-source completed successfully with 50 Flutter tests, 342 backend tests and all 50/100/500 synthetic PDFs with 150/300/1500 QR decoding checks. Windows hosted job was running at report authoring; confirm final state, do not infer PASS.

**Not completed**: Original Windows school machine startup/resume/reinstall, Android handset camera offline QR scanning and notice flow, printer duplex/front-back/focus/Indic font output, owner-owned Google Drive/Apps Script live import/five-PC integration, real elapsed 24h Recycle Bin expiry. These need actual device and owner provider access, not fake CI substitutions.

## Safety and acceptance

- PR #23 is merged; PR #24 and PR #25 remain separate drafts. PR #26 remains DRAFT and unmerged.
- No main merge, deployment, website download link replacement, school data deletion, forced ACK, billing change, or licence rule activation.
- All failures were retained in GitHub Actions history; intermediate analyzer/test failures corrected on later commits. Code existing is not the same as a verified live feature.
- Production rollout gate is **BLOCKED** until server, offline reader and original-school acceptance close, and real device/printer tests are recorded.

Evidence:
- https://github.com/cscticket01-hash/Saarthi_Ai/pull/26
- https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38135506374
- https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38135862862
