# Smart Sync 3.0 development evidence

Branch: `feature/smart-sync-3`; draft PR #23. Main starts at `de547d2c0a025db815ce97479e3f4f3fc4f8f1a8`. Production publication is not authorized.

## Current implementation (2026-10-10)

The existing local-first engine remains authoritative: durable SQLite writes enqueue original operation IDs, versioned cloud ACKs remove only the acknowledged queue version, and later edits survive failed requests and stale pulls. Changes add bounded recovery, hourly/wake scheduling, protected cache recovery, recycle inventory/restore, TEST recovery rehearsal, media-original retention and measured monitoring.

The control center now shows own-profile category counts, actual queue/conflict/document state, verified receipts, last ACK/reconciliation/backup, next hourly checkpoint, local application byte measurement, authenticated school API health and timestamped own-school Drive usage. Partial Drive inventories are labelled lower bounds. Local application bytes include all local profiles and backups and are explicitly labelled. Unknown download inventory remains unknown. Sanitized export excludes raw payloads, credentials, paths and record identifiers.

Central monitoring accepts bounded client version/conflict/document/checkpoint fields, replaces the whole report to prevent stale optional metadata, and distinguishes client observations from server durable-ACK evidence. Reports older than ten minutes are stale. Successful server evidence clears residual failure fields.

Offline tracked deletes now retain their original local snapshot and stable delete operation ID in the same database transaction as the hidden row and outbox. Snapshots remain school-scoped, survive restart, do not invent cloud deletion ACKs and do not purge financial evidence or file bytes. This preservation does not implement an offline restore choice.

## Verified evidence and active acceptance

- Local backend: 268 tests pass; focused monitoring includes school-scoped measured storage, malformed cache rejection and optional report replacement.
- Local OAuth/recovery/runtime checks: 21 tests pass. Shell syntax and source checks pass.
- Commit `d486f06d7e21a3a62872a2534c17b854ef5a7da1`: hosted backend, OAuth, school-isolation and Dart analysis pass. Web regression found three off-screen control-center test taps after added cards. Tests now explicitly reveal target controls and metrics; fresh hosted results are required.
- Isolated Render TEST deployment `dep-db4tjhajnfac738gbh60` is live at `d486f06d7e21a3a62872a2534c17b854ef5a7da1`. Production service is not changed.
- Exact-commit runtime health is required before TEST pairing/fixture writes. Missing, foreign or old runtime identity cannot authorize fixture writes.
- Native Android acceptance now renders the first frame before async plugin/network work and has a bounded twelve-minute driver timeout. A successful current-commit native chain is still required; previous emulator timeouts are not passes.
- Historical `f34dceee8d60c36cc17dccdc790b86cd0beceed5` cloud run 38025377350 passed storage, real engine and Chromium checks, then its Android job timed out. Downstream native readback was skipped.
- Historical recovery run 38024900611 verified an archive of 19 uploaded binaries, then failed in the private spreadsheet restore phase. Its original backup/restore operation IDs are preserved for bounded resume. The old diagnostic cache expired; a fresh failure must be inspected before assigning a cause.

Local Flutter setup was automatically blocked after a cloud metadata endpoint access was detected. That setup route is not retried; Flutter verification uses existing GitHub CI. Offline source formatting is separate.

## Fourteen requirements

| Requirement | Current implementation / remaining acceptance |
| --- | --- |
| Full control center | Measured health/storage/category/queue controls implemented; pending-download inventory and full clean-install restore remain incomplete. |
| Intelligent safe repair | Bounded typed retries, retained conflict history and explicit financial review implemented; unknown errors retain data. Original incident cause remains unconfirmed. |
| Hourly standby | Hourly/wake/reconnect scheduling tested with controlled timers; real elapsed-hour and physical sleep/wake remain unverified. |
| Instant local entry sync | Local durable saves and versioned TEST cloud ACK evidence exist; infrastructure latency is measured, not guaranteed instant. |
| Bidirectional recovery | Missing local-cache inventory, pending-edit/tombstone protection and verified cloud-record backup recovery implemented; full current-cloud acceptance remains required. |
| Protected 24-hour recycle | Signed cloud snapshot/restore, TEST expiry scheduler and local inventory UI implemented; offline local snapshot preservation added; integrated local restore remains incomplete. |
| Android independent of Windows | Shared school session and native harness implemented; current-commit native emulator acceptance pending. |
| Offline attendance | Durable SQLite queue, original capture time and duplicate protection implemented; current native restart/reconnect acceptance pending. |
| Massive concurrency | 1k/5k/15k durable component benchmark passes with mocked delivery; no measured provider throughput claim. |
| Photos | Original retention, distinct-original identity, approximately 30 KB best effort and actual synthetic cloud readback implemented; representative visual quality remains unverified. |
| Documents | Original retention, durable queue and approximately 50 KB best effort implemented; physical scan/seal/signature legibility acceptance pending. |
| Disaster recovery | Hash-verified local staging and separate private Sheets/Drive rehearsal implemented; cloud spreadsheet rehearsal and clean-install active cutover remain incomplete. Cloud cannot recover never-uploaded queues or credentials. |
| School isolation | Backend/Firestore/session tests and historical TEST foreign-school rejection pass; new exact-commit live acceptance pending. |
| Accurate central monitoring | School-scoped timestamped storage and separate client/server evidence implemented; fresh live monitoring acceptance pending. |

## Device acceptance procedure

Use only the isolated TEST school and preview artifacts from the exact tested commit. Record device/app commit, server commit and clock before starting. Create synthetic entries offline; record operation IDs, original timestamps and retained source bytes; close/reopen and confirm the queue and local snapshots persist. Reconnect, wait for actual durable ACK, retry the same operation, and read back the unchanged capture time without duplicates. Keep an independent pending edit during reconciliation and verify it remains.

For standby, keep the app open for a full elapsed hour, then separately sleep/wake and disconnect/reconnect; record actual checkpoint timestamps and absence of overlapping sync. For media, inspect representative photos, fine print, handwriting, signatures and seals before approving readability. For recovery, stage a verified local backup into a fresh directory and a cloud archive into a separate TEST workbook; compare every manifest hash, record/tombstone count and queue operation ID before any explicit clean-install activation. A staging pass does not certify active cutover.

Live 1k/5k/15k simultaneous provider tests require a separately approved capacity exercise and representative permits, cost/quota budget and measurement; a local/mock benchmark cannot substitute.

## Original-school incident

Request `7a8e0438-cc6c-443b-947b-14f7eb68f86f` at `2026-10-09T14:59:01.439Z`: HTTP 502, `SCRIPT_OPERATION_FAILED`. Underlying Apps Script category/source line remains unconfirmed. The original fee and two document pending entries remain untouched. No main merge, production release/deployment, billing change or pending clearing is performed.

Production readiness: **BLOCKED** until current acceptance and the explicitly incomplete requirements are resolved. Historical passes are not relabelled as current-runtime evidence.
