# Sync Engine 2 SQLite review boundary

This is a TEST-only review on `windows/easy-connect-draft`. Production hosting,
backend deployments, school records and original pending conflicts are unchanged.

## Storage and protocol

The existing Firestore-shaped local API delegates to one background SQLite worker.
Records use `(profile, collection, id)` keys. Indexed point reads and scoped writes
avoid decoding an entire large collection for a single edit. Local rows, pending
operations, receipts and conflict history commit together. WAL, synchronous FULL,
busy timeout, optimistic generation checks and integrity checks protect durability.
The bundled SQLite version must include the WAL-reset fix; unsafe versions fail
closed. Protocol 2, school identity, revision protection, operation IDs and original
capture timestamps are retained. Cloud ACK is still required before clearing an
operation; financial/document conflicts remain review-required.

## Migration consent and recovery

`SAARTHI_WINDOWS_SQLITE=true` enables the review adapter for fresh stores. Existing
JSON stores continue opening unchanged until the explicit migration API receives
approval. This API is not automatically invoked on an original installation.
Migration copies and hashes JSON, `.pending`, `.bak` and every LocalFiles file,
records the selected valid generation, verifies a canonical inventory of every
profile/collection/record, writes a temporary SQLite file, rechecks sources for
concurrent changes, and atomically renames only after integrity passes. Backups
are never reused or overwritten and are made filesystem read-only. Administrator
write privileges can override those attributes; this is not immutable cloud/WORM
storage. Journals and interrupted staging copies are retained.

Rollback requires explicit approval, unchanged originals and no post-cutover
edits. Otherwise reverting to stale JSON is refused. SQLite and its WAL must not
be copied independently while open; backups use VACUUM INTO. Network/UNC folders
are unsupported. Mapped network-drive detection and physical-device storage/
Defender behavior require additional verification before rollout.

## Confidentiality and remaining release gates

SQLite is not encryption. Student/financial records, original JSON copies,
LocalFiles and migration backups remain plaintext under their filesystem access
permissions, as in the existing local storage. Credentials stay in the existing
secure-storage integration; none are placed into migration manifests or TEST
browser drafts. Device encryption/access policy and any future compatible
at-rest encryption migration require a separate verified security decision.
Do not present this review as certified confidentiality or a production upgrade.

## Evidence scope

Hosted Windows tests exercise the existing production local APIs and Documents
screen with the adapter. A compiled child is actually killed before/after COMMIT;
an independent SQLite connection checks recovery. Synthetic benchmark sizes are
100, 1,000, 10,000 and 100,000 records, with 31 samples per case and p50/p95. Those
measurements describe the hosted runner, not a real-school PC or cloud SLA.

The separate TEST web entry point reuses authenticated managed-school endpoints.
Chromium intercepts its static assets locally under the allowed origin; it does
not deploy or exercise the production developer portal. Only the registered TEST
school and synthetic notices are permitted. The small persisted TEST input draft
contains no credentials and retains its operation ID/timestamp across reload;
this is not a new generic synchronization engine. Android OS evidence uses a
hosted API 35 emulator, not a physical phone. Original Pending 3, historical 5-to-3
reconciliation and the original-device QR remain unverified without their evidence.
