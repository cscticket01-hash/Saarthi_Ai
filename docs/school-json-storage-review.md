# School JSON storage review

Based on latest unmerged PR #49 head `b8a34ba1333c948cb23dbc738201de64b7e7d8c5`, preserving its document owner and student-view work. Main inspected: `16b9b6e8afe586aee9e9e702402dd523808114f5`. No deployment.

## Storage

The managed Apps Script record APIs default to JSON. Each of the 25 categories has a directory under its verified school root: `School JSON/<collection>/<collection>_<generation>.json`. Photos, PDFs and media retain their existing formats and binary APIs; JSON stores their metadata/references.

Schema 1 envelopes contain schoolId, collection, unique generation, createdAt, previousHead and a records map keyed by existing unique IDs. Existing revisions, operation IDs, deletion/recycle tombstones and application metadata are copied unchanged.

Under the existing signed request and Sync lock, writes create an immutable generation, independently read/hash it, then commit one Script Property `VS_JSON_HEAD_<collection>`. The committed head is read/hashed before an ACK. The single head property is the commit point; Drive overwrites are not claimed atomic. Previous generations and failed unpublished files remain as recovery backups. No backup cleanup occurs.

Sync protocol 2, CAS/conflict errors, mobile APIs and readback contracts remain. Local offline queues, retries and client engines are unchanged; no Firebase architecture changes.

## Migration

First locked category access reads its verified authoritative Sheet (organized partitions if active), or unmigrated legacy JSON; writes a generation and verifies the records hash. Original Sheets/rows, media and source files are never rewritten. Empty categories create no Sheets. Foreign schools, duplicates, source disagreements, missing verified tabs, pending workbooks and incomplete layout migration block cutover for owner review.

`VS_JSON_CUTOVER_<collection>` prevents missing heads from silently reading stale Sheets. Selecting historical `VS_RECORD_STORAGE=sheets` is rejected after JSON cutover. Sheet layout mutation APIs reject JSON-mode operations to prevent stale migrations/media moves. Optional student import Sheets remain input tools; imported records use JSON. Existing readable student Sheets are preserved historical views, not updated by JSON writes. Backup census and delta reads use committed JSON.

After approval, upgrade existing Apps Script source/deployment preserving Script Properties, school ID/root/secret and /exec URL. Do not rerun setup. Do not roll back to stale Sheets after JSON edits; recovery requires review of retained generations.

## Verification and limits

Synthetic VM tests cover CRUD, CAS, duplicate retry, all categories, Sheet preservation, foreign schools, corrupt data, storage outage, pointer-commit crash, fresh VM restart, mobile notice deletion, backup and delta reads. Historical Sheet fixtures explicitly choose pre-cutover Sheet mode.

Existing 512 KiB record limit retained; JSON categories are limited to 20 MiB UTF-8. Every write copies the entire category and retains prior generations. Large attendance histories require measured capacity testing and a reviewed partition/compaction design before production rollout. Real Apps Script execution time, Drive quotas and latency are not established by VM tests.

Physical Windows/Android and live authenticated Drive ACK/readback remain unverified. No real-school data operations, queue clearing, merge, release or deployment occurred.
