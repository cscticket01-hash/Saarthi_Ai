# Record-focused Smart Sync audit and implementation

| Rule | Existing code | Change |
|---|---|---|
| Initial sync, hourly idle check | Hourly owner dispatch already present; idle heads fallback was 30 seconds | Heads fallback is hourly; live remote change hints and reconnect still wake the owner |
| Unchanged Save | Directory no-op already present | Save-generated metadata timestamps ignored for all normal collections; no disk commit/snapshot signal when no business data changes |
| Same-record edits at any later date | Whole-record CAS write | Durable baseline and capability-gated changed-field envelope; no date expiry; unchanged photos excluded |
| Photo retries | Content-keyed file deduplication | Frozen prepared wire payload survives restart, avoiding repeated upload; canonical ACK restores verified file references locally |
| Concurrent edits | Whole-record revision conflict | Script merges independently changed fields; per-field revision proof protects stale same-field edits and ABA. A lost ACK never permits blind overwrite |
| Duplicate new Add | Only identical readback automatically adopted | First cloud create retained for the same logical key; losing draft archived; student child ownership protection retained. New teacher additions use a stable school-local phone key. Distinct financial operation IDs remain distinct events |
| Delete after conflict | Prior conflict could remain attached to delete | Explicit delete is admitted; same-person authenticated readback can advance its CAS base without changing its operation ID or breaking document-cleanup receipt linkage |
| Fake spinner | Whole engine run animated, including local work | Only active school API transfers animate. Local preparation is labelled separately; quiet event subscriptions do not animate |
| 3 records becoming 6 pending items | Owner deletion creates document cleanup jobs | Cleanup jobs are explicitly labelled and counted; they are not additional people |

Field-only transport requires the new Script capability `recordFieldPatchVersion:1` (bundle 2026-10-25.1). Point preflight capability checks a new logical key before uploading duplicate media. Existing protocol-2 broker routes already carry the signed envelope; no broker/Render deployment is required. Older Scripts continue safe full-snapshot CAS and do not receive an unsupported envelope. Existing queued wire modes/payloads never change on upgrade.

Deploy the generated SaarthiManagedAll.gs into the EXISTING school deployment, preserving Script Properties, School ID, root, shared secret and /exec URL. Do not run new-school setup, create new storage, or reset school data. GitHub publication is not evidence that a school's private Script deployment was changed.

Tests cover actual JSON/SQLite writes, immutable retry payloads, canonical ACK/media reuse, first-create readback, deletion linkage, late ACK/newer edits, hourly idle decisions, and the signed Apps Script implementation including disjoint field edits, lost ACK, same-field conflicts, ABA, ownership, deletion and profile protection. Original school queues/records require runtime verification; no private school data is used by CI.
