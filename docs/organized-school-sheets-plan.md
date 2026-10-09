# School-owned Drive organization and migration plan

Status: resumable executor implemented and fixture-tested; no live school migration executed.

Reuse the verified school root ID. Its display name may become `Vidya Saarthi — SCHOOL_ID` only after inventory, backup and approval; readers use IDs, never folder names. Do not create a replacement root. All Sheets remain private to the school owner; authenticated, signed school-scoped broker access remains mandatory.

| Sheet in school root | Authoritative source and partition |
| --- | --- |
| 01_Students | students_directory |
| 02_Teachers | teachers_directory, verified teacher roles |
| 03_Other_Staff | teachers_directory, verified other-staff roles |
| 04_Student_Attendance | attendance_records/attendance_logs, verified student role |
| 05_Teacher_Attendance | teacher_attendance/attendance_records, verified teacher role |
| 06_Staff_Attendance | same attendance sources, verified other-staff role |
| 07_School_Fees | fee_ledger and fee_payments in separate tabs |
| 08_Fee_Structure | fee_settings, preserving class and academicSession |
| 09_School_Expenses | school_expenses |
| 10_Examinations | exams |
| 11_Exam_Results | exam_center_results and exam_results in separate source tabs |
| 12_Staff_Salary | teacher_salary, preserving teacher/staff identity |
| 13_School_Notices | school_notices |
| 14_School_Profile | school_config and school_settings in separate tabs |
| 15_Academic_Sessions | existing rollover/session configuration plus school_calendar in separate tabs |
| 16_Documents_Metadata | documents and backup manifests in separate tabs |
| 17_Other_School_Records | existing operational collections and unresolved role review tabs |

Unknown staff roles or attendance ownership must be placed in the migration review report; never guess a teacher/student classification. Preserve the original collection and record ID, even when rows move into a role partition. Exam results retain both source identities; UI deduplication is not permission to delete one source.

Each source tab retains stable recordId, schoolId, academicSession, revision, operationId, updatedAt, tombstone state and the complete canonical record payload. Preserve the existing inert JSON-fragment storage encoding, arbitrary fields and decimal amounts. Add human-readable columns as derived views only; Sheets edits must not bypass revision checks. Formula-leading strings remain inert. Stable IDs and file references remain unchanged.

## Binary storage

Create or reuse verified subfolders within the same root: Student_Photos, Teacher_Photos, Staff_Photos, Student_Documents, Teacher_Documents, Staff_Documents, Other_Files, ID_Cards, School_Assets and Backup_And_Recovery. An existing folder ID may keep its name during compatibility rollout. File metadata references fileId, documentRevision, MIME type, size and existing URL; no image/PDF/base64 is stored in Sheets. References to external/foreign roots fail review. Unresolved ownership routes to Other_Files without guessing. Moving a verified file preserves its ID and URL; old files are never automatically deleted.

## Inventory and backup gate

1. Run owner-only `VS_inventoryManagedStorage()` against the intended staging school; require partial=false. This lists root/workbook/folder/file metadata but does not constitute a record backup.
2. Export source collection IDs, all record IDs including tombstones, revisions, operation IDs, sessions, canonical record hashes, Sheet/tab IDs, file IDs, ancestry and access permissions. Detect duplicate IDs within each source, foreign schoolIds and broken references.
3. Create an immutable recovery snapshot and manifest; verify every row count/hash and referenced file hash/size. Restrict access to the school owner. Do not rotate connection secrets or publish Sheets.
4. Obtain separate approval before any real school's migration or file relocation. A staging service connected to the central Firebase project does not make real school records disposable test data.

## Staging migration and activation design

Use a versioned layout registry keyed by schoolId and original collection, recording destination spreadsheet ID/tab/partition. Reuse a matching verified destination; duplicate name matches block execution. A resumable manifest keys each row by source collection + recordId + revision and records progress and verified hashes. Re-running a batch must not create duplicate rows or Sheets.

Keep current layout authoritative during copying. Capture a source revision checkpoint, copy bounded batches including tombstones, verify schoolId/count/hash and reconcile changes after the checkpoint. A conflicting revision retains both versions and blocks activation. Do not acknowledge an operation against the new layout until its authoritative row is durable and verified.

Activate each collection only after complete verification under the existing school lock. Both layouts remain readable through the registry during rollout; writes use one active route, never an untracked dual writer. Role changes retain the old payload with a redirect marker and verified previous-content hashes. A crash before activation resumes the manifest while the old route remains usable. Rollback restores the registry route and replays post-checkpoint operations, preserving their original IDs. Retain sources and snapshots until a separately approved retention policy exists.

## Acceptance gates

- Isolated test-school write/read, repeated batch, interruption/resume and revision conflict.
- All 17 destinations verified; no duplicate workbook, record, root or photo.
- Existing Windows/Android readers, authorized website exam viewer and old file URLs still work.
- Cross-school read/write and foreign-file access rejected.
- Tombstones and offline retries cannot resurrect deleted records.
- Fees, marks, pass/fail/promotion rules and academic sessions unchanged.
- Measured Drive ACK and client visible revision with correlated operation IDs.

## Owner-only executor runbook

Install the reviewed generated `SaarthiManagedAll.gs` in an isolated test-school Script. Preserve its existing root, school ID, secret and deployment URL. Installation alone does not start migration. Do not run these functions against a real school during draft testing.

1. First call `VS_previewOrganizedStorageMigration()` and review counts, hashes, target partitions and oversized files. It performs no writes. Then call `VS_beginOrganizedStorageMigration()` once. It creates the resumable job; repeated calls return its status.
2. Repeatedly call `VS_stepOrganizedStorageMigration()`. Each call copies at most 25 records or 5 binaries, under the existing lock. Check `VS_organizedStorageStatus()` after every call. Collection checkpoints are validation-time counts, not live inventory counts.
3. A collection becomes authoritative only after source/target canonical hashes match and a verified activation snapshot exists. Concurrent legacy edits restart reconciliation. Review tabs preserve records with unknown roles.
4. Binary relocation starts after record migration. Original-byte backups and audit manifests are verified before moving the same file ID. Sources, snapshots and pending queues are retained.
5. For rollback, repeatedly call `VS_rollbackOrganizedStorageMigration()` until rolledBack. Current organized records, including post-activation edits and tombstones, are copied back before the route switches. Binary parents are restored with byte checks. A completed rollback is terminal for this job; begin does not silently restart it.

Safety limits deliberately stop oversized work: 20 MB per collection snapshot or binary, and 5,000 inventoried entries. Unmarked creation orphans, duplicate books, ambiguous parents, changed files, foreign ancestry and corrupt backups pause with an error; resolve through owner review without deleting source data. This executor does not automatically create a scheduled trigger, alter permissions or migrate external Drive files.

## Cloud verification and device acceptance

The existing mobile dashboard now includes examination definitions and the student's assigned-class fee structures. The website's managed live view reads signed school-scoped delta groups every 15 seconds while visible; unchanged revisions avoid repeated payloads. Existing FCM hints and mobile fallback/resume refresh remain in place. School Windows uptime is not required for these cloud reads.

Fixture integration tests exercise protocol-2 write → durable Script ACK → authorized mobile and website reads, pending-operation retry, rollback and cross-school rejection. They do not measure network latency or prove real-device behavior.

For real acceptance, use an isolated school and fresh TEST builds. Record UTC time, operation ID and revision for a Windows edit; record the cloud ACK time, queue count before/after, and Android/website visible revision and time. Repeat for exams, fees and notices, with Windows off after ACK and with an offline queued edit resumed. Capture screenshots/logs and verify that unrelated pending items remain. Do not clear the queue or write to existing school records. No real-device PASS or timing is recorded until these steps are performed.
