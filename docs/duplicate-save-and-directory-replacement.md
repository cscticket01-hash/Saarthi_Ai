# Repeated Save and directory replacement

Repeated Save of the same record now preserves the existing local value and
the exact queued operation, retries and diagnostics inside the serialized local
writer. After a verified ACK, unchanged Save creates no new upload. Changed
values still replace the same document ID and queue a new revision-checked
operation. Directory creation/update timestamps and server `_syncUpdatedAt`
do not create false content differences. Actual financial dates, person
identities, photos, school identity and lifecycle markers remain significant.

Identical authenticated cloud readback can retire a redundant directory upload
without manufacturing an ACK. Both copies and the verified revision are audited.

A changed, explicit Save of an existing student/teacher conflict can replace
that same person's cloud value using the latest authenticated conflict revision
as its CAS base. Background retries and unchanged Save never select a winner.
Another intervening cloud change conflicts again. The old local value and cloud
snapshot remain in conflict history. This rule excludes different person IDs,
deletion/recreation, documents and financial conflicts. Validation failures can
retry after an actual correction; authorization/configuration diagnoses remain.

The Add Student and Add Teacher callbacks reject a second concurrent invocation
before starting asynchronous work. Existing add-form duplicate identity checks
remain; names/phone similarity never merge separate people.

The settings error now reports version conflicts separately from other attention
items. Original-school pending reasons cannot be established from screenshots:
they require authenticated per-record queue/readback evidence. This change does
not delete those pending records or promise all three are resolved.

Regression workflow covers concurrent Save, unchanged Save after ACK, changed
Save using a durable baseline, timestamp differences, readback reconciliation,
explicit same-person replacement, retained history, protected person/deletion/
financial states, corrected validation and retained permission diagnostics on
both JSON and SQLite storage.
