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

Second stage: existing Advanced Settings shows the proposed universal format without enabling unverified allocation. Teacher search accepts existing teacher/public UID. The existing manifest designer preview no longer renders PDF; its explicit export retains the print renderer. The school-wide apply review gate remains unchanged; other card paths and actual allocation remain pending. The consolidated CI moved runner.temp into step-level environment.

Third stage: new managed teacher records use immutable randomly generated document/payroll keys and stable person generations; legacy keys and employee history are preserved. Staff records use randomized generation IDs and compare-and-set directory writes. Native preview/printing/download is now routed from student and Other Staff directory screens and selected manifest teacher templates. Legacy numeric teacher layouts, background published-card compatibility, actual UID activation/allocation/migration and client sync remain pending. No existing PDF backup or mobile authentication owner has been disabled.

Fourth stage: existing live Worker supports exact current-generation student/teacher UID reservation in an initialized ledger. One transaction creates the immutable school_config projection and ordinary backup job; person ACK and fee/QR keys stay unchanged. Broker validates the current school and person and rejects generic writes to UID projection IDs. Activation remains restricted to an explicitly synthetic, empty TEST school; production requires verified existing and retired inventory migration and restore. Existing Advanced Settings reads server status and counters. Automatic post-ACK reservation, staff authority, legacy teacher templates and mobile card publication replacement remain pending.
