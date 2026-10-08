# Historical Pending 5: safe acceptance and reconciliation

Scope: TEST artifacts and an explicitly authorized school/device. Do not delete
pending rows, uninstall the current app, clear app data, force a revision, migrate
real school storage, or replace a production Apps Script deployment.

## Evidence currently available

Render managed/records HTTP409 at 2026-10-08T14:59:40.320261448Z,
reference 501a5fa4-7629-4417-814c-036026b7e954, code UNKNOWN.
The historical logs contain no school ID, operation ID or response body.
The historical cause and current count are unconfirmed.

## Device procedure

1. Preserve a verified backup of the complete local database/outbox and linked
   originals. Work on a copy for inspection; do not edit its queue. Record the
   installed version, verified school ID, time zone, current pending count and
   last-successful-sync value. A reported historical count of five is not a
   measured current count.
2. Use the existing authorized account. Never send passwords, tokens, student
   records or complete raw request bodies in chat. Collect only safe error code,
   reference ID, operation ID, collection, record ID and local revision for each
   pending item. Check that the device is connected to the same school.
3. Read the school-scoped cloud record and its operation receipt using the
   authenticated adapter. Do not infer completion from a matching name/count.
   Compare the pending operation ID, expected base revision, local content,
   verified server operation receipt and cloud record revision.
4. If a verified receipt matches the exact pending operation, retry the same
   operation ID through normal sync to obtain its idempotent server ACK. Only
   the existing queue ACK handler may mark it complete. A lost response after a
   successful write must not create a second operation.
5. If the expected base revision is current and no receipt exists, retry the
   unchanged operation ID. Read back its school/record identity and ACK.
6. If cloud and local diverged, retain both versions and stop automatic retry
   for that item. Obtain authorized field-level resolution. A resolved edit is
   a new operation based on the freshly read cloud revision; retain the original
   conflict evidence. Never blindly replace expectedRecordRevision to force a
   write or overwrite a newer local edit with an older response.
7. SCHOOL_STORAGE_NOT_CONNECTED requires the developer to verify the existing
   school's managed storage binding. Do not create replacement school folders
   or overwrite an existing Drive connection. Identity/license failures require
   normal account verification, never bypasses.
8. Record actual before/after counts and individual dispositions. Conflicted or
   unacknowledged items may legitimately remain pending. Zero is not a goal
   independent of verified reconciliation.

## Coordinated isolated TEST-school acceptance

Use distinct School A/B and authorized Windows, Android and Web accounts.
Preserve all baseline records and links. Record event capture, local save,
queue dispatch, backend receipt, durable acceptance, final Drive/Sheets ACK,
Android visibility and Web visibility separately. Do not label queue acceptance
as final cloud ACK. Sample repeated events and report p50/p95/p99 with network,
service deployment SHA and client versions.

Check minimized Windows, closed Windows cloud reads, airplane-mode recovery,
restart during upload, replay after lost ACK, concurrent edits, foreign-school
rejection, second-PC document restoration and Fees 30-second App Lock.
A terminated Windows process cannot upload unsynced edits.

For Sheets migration, use only isolated TEST school: verify backup counts and
content hashes; dry-run category mapping and stable binary references; interrupt
and resume; validate counts/content; inject a concurrent edit; test rollback on
TEST copies and verify it preserves the concurrent record. No real-school
migration is authorized by this procedure.

Physical device, authenticated school storage and Drive owner access are required.
Unavailable steps remain BLOCKED, not PASS. Debug APK must use an isolated
TEST device/profile; never uninstall the real app to work around signer/version
mismatch.
