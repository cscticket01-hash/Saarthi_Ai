# Final sync and organized storage review — 2026-10-08

The existing School ID, Drive root, Script secret, /exec URL, workbook IDs, file IDs and historical rows must remain authoritative. This change does not execute a live migration or create a second Sync Engine.

## Existing storage and requested layout

The existing managed adapter already reuses one school root and the `School Data / Vidya Saarthi School Data` workbook. Collections have versioned tabs, stable IDs, inert canonical JSON fragments, revisions, tombstones and bounded resumable legacy backfill. Binary files remain in `Files / Photos`, `Files / Documents`, and backups in `Backups`. Windows and Android continue using authenticated school-scoped access.

| Requested school records | Existing authoritative collection/tab |
| --- | --- |
| Students | students_directory |
| Teachers and Other Staff | teachers_directory, with existing role fields preserved |
| Student attendance | attendance_records / attendance_logs |
| Teacher/staff attendance | teacher_attendance, preserving existing staff roles |
| School fees | fee_ledger / fee_payments |
| Fee structure | fee_settings; session-specific records preserve legacy class records |
| Expenses | school_expenses |
| Examinations | exams |
| Exam results | exam_center_results / exam_results |
| Salary | teacher_salary |
| Notices | school_notices |
| School profile/assets references | school_config / school_settings |
| Academic sessions | existing session fields and rollover settings |
| Documents and ID metadata | documents |

The requested 16 named Sheets and separate photo/document/assets subfolders are not live-migrated by this deployment. Creating another set alongside the current workbook before an approved mapping would duplicate storage and risk breaking readers.

## Required inventory and migration gate

Before moving real records/files, obtain an owner-authorized inventory of the current school's root, nested folders, workbook/tab IDs, record IDs/revisions/counts, binary file IDs, MIME types, ancestry, existing references and permissions. Record unresolved/foreign/duplicate references explicitly. No Drive account/editor access or real inventory is assumed from an /exec URL.

Create and verify an immutable backup and complete manifest. Keep current operational IDs and file URLs. Test the mapping on isolated non-production data, including interruption/resume, two-PC readers, Android, tenant isolation, conflicting revisions and tombstones. Count/hash all migrated rows and validate file references before changing a layout registry. Existing readers must support both layouts until verification and owner approval of a live migration. Legacy sources are retained, never deleted automatically. An interrupted migration must leave the current layout usable.

The owner-editor-only `VS_inventoryManagedStorage()` now returns existing root/workbook IDs and descendant folder/file IDs, paths, MIME types and sizes, capped at 5,000 items with an explicit `partial` flag. It is not routed through the web API and does not create storage, backfill records, move files or return connection secrets. It has been tested with an isolated read-only fixture, not run against a real school. A complete record/revision inventory and verified backup are still required; this metadata listing alone does not approve migration.

Exam Centre-only results now participate in the managed Android dashboard's existing revision feed alongside `exam_results`. Both collection revisions form the checkpoint; unchanged checkpoints skip result reads. Duplicate IDs select the latest timestamp, and a tombstone in either source suppresses the duplicate. Existing person authorization is retained. The change and owner inventory helper are local source only, with no production Apps Script update.

No live migration, workbook renaming, new school root, secret rotation, file move, billing change or historical-record deletion is authorized by this review. A separate explicit approval is required for real school-data migration.

## Performance acceptance still requires real devices

Measure Windows durable-save completion, verified Drive ACK, Android refresh start/end and visible revision. Correlate operations and report sample count, p50 and p95 across foreground/minimized Windows, Android foreground/resume, network recovery and two-PC restoration. Local CI timings and injected remote ACKs are not provider/device acceptance.

Closed Windows processes cannot upload new local data. Already acknowledged cloud records must remain readable by authorized Android clients independently of the Windows process. The existing broker deployment can provide that cloud availability without introducing a Windows background service.

Quota controls: durable mutation events, bounded 250-ms coalescing, school/person-specific content-free FCM hints, unchanged/delta reads, bounded health/metadata caches, and exponential failure/quota retry backoff. No high-frequency full-Sheet polling or new Firestore record mirror is introduced. Actual daily usage and remaining quotas must be measured; no finite quota is guaranteed never to exhaust.
