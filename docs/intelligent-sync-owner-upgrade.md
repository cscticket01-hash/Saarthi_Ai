# Existing Sync Engine 3: evidence-based owner repair

This extends the existing engine; there is no independent repair scheduler or second record authority.

Preserved rules: startup verification then hourly idle checks; immediate durable local changes; unchanged Saves do not enqueue; exact original retry requests; any-date same-record field edits; first committed same-key Add; protected student generations and financial events; explicit tombstones only; existing recycle retention; no fabricated ACK or spinning while idle.

Implemented: durable received notification inbox and independent applied progress; exact record hints/point reads with bounded collection fallback; write-ahead notification intents with verified recovery across broker restart; at most five owner repair probes per admitted run with persisted cooldown/history; recovery of legacy teacher delete identity from its original atomic snapshot; capability-gated batches of at most ten independent writes with individual receipts, partial success and exact replay. Existing directory/file/delete dependency ordering is retained. No cross-record atomicity is claimed.

A received cursor is not a record apply ACK. Inbox work persists before received cursor advancement and is removed only after verified apply. Exact reads merge selected record revisions and retain the whole-collection checkpoint, so an unrelated update cannot be skipped. Missing point-read records never mean deletion.

Notification intents are metadata-only, persisted before protocol-2 writes. A failed prepare prevents that write rather than pretending delivery is reliable. Failed post-commit publication retains its ticket. Recovery is bounded, school-isolated and claimed transactionally; prepared tickets require authenticated same-operation proof. Duplicate notifications are safe. Unproven intents are backed off, and obsolete unproven notification metadata may expire after 24 hours; record queues and deletion receipts are unaffected.

Self-repair diagnoses exact durable operations, preserves newer local edits via the existing serialized CAS writer, and reports retry admission separately from verified completion. Authorization, quota, unknown errors and real same-field conflicts are not blindly reopened. Existing owner timers, pause and profile isolation remain authoritative.

Deployment requires the updated broker and the supplied bundle in the existing school Script project. Preserve School ID, root, secret, Script Properties and deployment URL. Private school pending rows and physical devices have not been directly verified. Missing credentials or an inaccessible school Script cannot be repaired by guessing.
