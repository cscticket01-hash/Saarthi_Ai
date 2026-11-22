# WIN-005–007: UID registry foundation (unpublished)

Stage only, not a completed feature or production activation. No school records
are rewritten. Registry is not yet connected to live worker ownership or client;
never initializeSchool from unverified client inputs.

Approved: CATEGORY-SCHOOL4-PERSON4-000001. STU and TCH separate counters,
Office Staff and Other Staff share STF. School identity is authenticated
schoolSyncId. Four uppercase Unicode letters, ignore punctuation/digits and
pad short names with X. Existing assignments and legacy UIDs are preserved.
Recognized existing new-format serials seed the corresponding high-water mark.
No counter reset, release, TTL or reuse; exhaustion fails closed.

Remaining: verified complete active/retired legacy inventory, durable backup and
restore proof, owner-bound worker integration, all Windows create/import and staff
paths, stable fee ledger migration, teacher ID independent of mobile, timetables,
settings activation/resume, UID display, native PDF-free ID card preview/printing.
No changes to existing QR credentials or UID values. No deployment or publication.

Single branch-scoped CI tests SQLite registry, Cloudflare type check and Flutter
regressions. Existing workflows are not modified.
