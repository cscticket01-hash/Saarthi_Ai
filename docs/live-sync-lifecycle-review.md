# Live authority lifecycle admission review

This review distinguishes existing verified Drive/Sheets functionality from the
new temporary Cloudflare live authority. It does not claim that every existing
collection has migrated. No school rollout flags are changed by this review.

## Current admission boundary

The broker (`functions/live-sync.js`, `COLLECTIONS`) and Worker
(`cloudflare-sync/src/live-records.ts`, `liveCollections`) currently admit only
`school_expenses`, `school_calendar`, `school_notices`, and `school_settings`.
Student, teacher, financial-ledger, attendance, examination, binary-document and
recovery collections retain their existing owners. Other staff use
`teachers_directory` (`lib/windows_other_staff.dart`); there is no separate
`staff_directory` live collection to add.

The new `cloudflare-sync/test/live-lifecycle-admission.test.mjs` sends correctly
HMAC-signed requests for 18 unsupported collections. Each seed, read, commit and
snapshot request must fail with HTTP 412. It then verifies that collection
metadata, event cursor, backup jobs and all retained payload counters remain
empty. This tests the actual Worker admission boundary, not an exported list.

## Requirements before broadening admission

| Flow | Existing protection and source | Required live-authority work |
| --- | --- | --- |
| Student create / slot reuse | `VS_managedRecordUnlocked`, `school-backend/managed/SaarthiManagedAdapter.gs`: stable pupil generation, explicit replacement generation, revision CAS, retired-generation markers | Admit the generation and replacement transaction as a domain operation. A class/roll document ID alone cannot distinguish successive pupils. |
| Student delete | `VS_deleteStudentOwnedRecords`, same file: tombstones explicit owned documents, attendance, fee rows, examination rows, scan index, sessions/users/complaints; removes historical JSON snapshots; retains shared Drive file references | Commit parent retirement and all child tombstones as one recoverable operation with generation-bound ordering. Persist progress through crashes. Emit hints for every affected collection. Reject delayed child writes belonging to retired generations. |
| Student offline duplicate | `firstCommittedCreateWins` in `lib/windows_record_change_policy.dart` and `recordOutboxConflict` in `lib/windows_local_firestore.dart`: exact school/record identity, explicit fresh-create intent, verified original, linked-child guards, atomic local adoption | Reuse these protections with authenticated canonical live readback. Never infer equivalence from name/phone or clear a local queued operation using an unrelated operation ACK. |
| Teachers and other staff | `teachers_directory`, stable teacher identity, document and salary ownership; `VS_session` and `VS_own` in `SaarthiManagedMobile.gs` | Define teacher retirement/recreation, salary and document dependencies, mobile credential revocation and re-enrolment before generic CAS admission. Staff are not independent administrative rows. |
| Fees and salary | `firstCommittedCreateWins` expressly excludes `fee_payments` and `fee_ledger`; `VS_reusableStudentChild` and generation logic prevent a fresh pupil inheriting a previous pupil ledger | Preserve payment identity, ledger/month ownership, collection/modify/reversal policy and receipt versions. A generic identical-content create shortcut is insufficient for financial transactions. |
| Attendance | `functions/attendance-queue.js`, `functions/test/attendance-queue.test.js`, `SaarthiManagedMobile.gs` attendance policy: verified person, schedule window, original captured timestamp, stable event, per-operation partial ACK and delayed retry | Retain that dedicated admission and batching domain. A live record write cannot bypass mobile session, schedule, location or one-entry-per-day policy. Photos remain dependent file operations. |
| Documents and photos | `functions/cloudflare-delivery.js`: immutable upload manifest/key, byte count/hash, resumable part offset, verified Drive file ID. `managed/records` document CAS additionally forwards document version expectations | Coordinate temporary bytes, metadata record and owner generation. Purge bytes only after exact verified Drive content and metadata handoff; retain newer revision and shared references. Do not replace file protocol with a JSON record commit. |
| Android projections | `VS_session`, `VS_own`, `VS_safePerson`, `VS_managedMobileUnlocked` dashboard logic in `SaarthiManagedMobile.gs`: role/person-scoped projections, safe fields, session validity | Provide a person-scoped projection and cursor domain. Never grant a student or teacher the school-admin replay stream or snapshot. Authenticate current pupil generation when replaying after offline deletion/recreation. |
| Recycle restore and recovery | `managed/recycle` in `functions/managed-schools.js`; versioned restore ownership in GS; `lib/windows_recycle_bin.dart` | Freeze the relevant authority during restore, reconcile restored revisions to live metadata, and prevent stale events from undoing a restore. Generic replay does not supply this lifecycle. |

## Existing regression evidence to preserve

These are existing suites rather than new duplicate implementations:

- `functions/test/sheet-lifecycle.test.js`: explicit deletion/linked rows, fresh
  slot reuse, stale-device rejection, lost delete ACK, repeated occupant
  retirement, fresh monthly ledger and shared-photo preservation.
- `functions/test/managed-sheet-lifecycle-routes.test.js`: authenticated
  school-bound recovery and generation-bound deletion transport.
- `functions/test/attendance-queue.test.js` and
  `functions/test/attendance-schedule.test.js`: durable admission, batching,
  restart, partial ACK, quotas, school isolation and schedule rules.
- `functions/test/document-delete-ack-contract.test.js` and
  `functions/test/managed-student-readable.test.js`: versioned document ownership
  and delete replay.
- `test/windows_multi_pc_sync_test.dart`: independent local SQLite stores and
  verified offline duplicate adoption. This is not a physical two-PC test.

## Migration integration finding

Legacy accepted Cloudflare deliveries must be allowed to drain after new user
writes are fenced. In `managed/cloudflare/drain`, records/file delivery must invoke
the internal signed legacy execution path rather than re-enter public legacy
admission. Notice delivery already uses the direct signed Script path. The drain
bypass must remain confined to the HMAC-verified internal handler. Otherwise a
nonempty old queue and a preparing migration block each other permanently.

All previous broker deployments must be retired before the drain grace period
starts. A legacy broker that does not participate in durable admission can
still accept writes after the fence and invalidate the baseline.

## Release evidence still required

The new authority has record-level CAS, operation replay, temporary handoff and
Drive readback tests. Those tests do not prove the domain operations above or a
production release. Before admitting additional collections, add executable
end-to-end tests for the particular lifecycle, lost response/restart boundaries,
foreign-school and foreign-person requests, late offline writes, Drive cleanup
and newer edit protection. Run school-isolated cloud acceptance and release
builds after client routing is integrated. Physical-device and load latency
claims require measured runs; unit tests cannot establish them.
