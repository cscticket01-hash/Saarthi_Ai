# Complete Google Drive proof gate (19 November 2026)

This branch adds a **read-only, fail-closed reconciliation core**, not a production
backup certificate. Do not report that school backups are complete based on
synthetic tests, Drive root listings, R2 objects, HTTP 200, or limited UI history.

Before actual production certification, authenticated server adapters must:
1. Enumerate all source journals including records, files, notices, attendance,
   live operations, historical/legacy queues, and local outboxes. Even empty
   sources must prove full, school-scoped enumeration.
2. For each immutable original operation independently obtain a signed school
   Google Apps Script/Drive readback of revision or exact file ID, bytes/hash
   and original identity. Preserve uncertain and unresolved jobs.
3. Persist **original** verified timestamps for exact closed-hour reporting.
   Unknown historical times must remain uncertified, not stamped with discovery
   time or Cloudflare acceptance time.
4. Supply authenticated inventory and owner readback callbacks to the audit
   module, then display complete counts only when every source has passed.
5. Recheck exact deployed school Script version, production provider connection,
   old receipts and source-specific client compatibility before merge/deploy.

Existing PR #343 R2-only hourly summary remains **partial** until these
provider-backed adapters and production proof are deployed. Unit tests are
synthetic invariant tests; they do not prove real production completeness.
