# Sheet records and student lifecycle

Implementation based on main 02d71bf. No real-school test writes, deployment or publication.

## Record authority and recovery

The upgraded default uses school Sheets for records and a separate school-bound Sync State workbook for hashes, revisions, operation identity and retired student generations. No personal record payload is stored in Sync State. Per-record JSON backup files stop on this path. The backup button produces an independently readback-verified Sheet census instead of the legacy folder-only JSON export.

Existing JSON-mode categories move to Sheets under the existing Script lock, preserving their verified source generations. Cutover copies at most 100 changed rows per attempt, refuses unrelated target rows and publishes authority only after full canonical readback. Read-only backup census follows the completed per-category authority, never a stale JSON head.

A trashed original school workbook is restored by verified ID/marker. An unavailable workbook can be recreated only with retained school sync-state proof; permission errors fail closed. The desktop keeps exact last-verified server record payloads locally. Missing cloud rows accept only the same-school, same-revision payload whose hash matches retained server state; pending edits remain separate. Missing deletion rows produce minimal tombstones rather than resurrecting payloads. Unknown or unavailable proof remains unverified. Losing all cloud state AND every verified local copy cannot be repaired by inventing records.

## Student identity and deletion

Class/Roll is a reusable slot; a new student receives a random stable generation. Explicit deletion cascades through exact linked student records, revokes the effective old mobile identity and removes individually identified legacy per-record JSON snapshots. A generation-bound delete may supersede edits to that same occupant, but cannot delete a replacement occupant. A new occupant and new ledger can reuse the slot while stale phones/PCs are rejected. Minimal retirement markers survive multiple occupants.

Local linked records disappear with the explicit delete. Verified cloud deletion purges old queued edits, related local payload/history/cache and app-managed document copies; a durable cleanup journal retains file failures for retry. Newer occupants, foreign schools, shared files and picked source originals are protected. Student-directory operations precede child publication. Offline devices observe central deletion on their next authenticated sync; no immediate offline-device erasure is claimed.

Whole-school historical archives and unrelated migration sources are retained because they can contain other students. This change does not claim erasure of arbitrary copies, external exports or every historical archive. Ambiguous ownership remains for review rather than broad deletion.

## Windows updates

Both updater entry points share exact release URL/version validation, mandatory release SHA-256 and size verification, bounded headers/body/overall transfer and temporary-file cleanup. A failed download does not replace an existing installer or start it.

## Rollout and validation

Use the new authenticated backend routes, then upgrade the existing Apps Script deployment to bundle 2026-10-16.1 while preserving School ID/root/secret/exec URL, then publish clients. Do not rerun new-school setup or reset Script Properties. The live Render deployment uses windows/easy-connect-draft, so its matching broker-only patch must be reviewed separately rather than deploying main over it.

Synthetic VM, actual Dart/Flutter and SQLite tests are required. A successful build is not real Google Drive execution-time/quota evidence, a physical Windows/Android acceptance test or a guarantee about the user's pre-existing conflict.
