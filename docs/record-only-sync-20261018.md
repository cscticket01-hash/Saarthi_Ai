# Record-only Windows sync and Apps Script 2026-10-18.1

Normal automatic and manual Sync Now runs no longer request an hourly full
inventory audit. After initial download, collection-head comparison selects
changed collections. Persisted per-record revision checkpoints let the Script
return only added, edited and explicitly deleted records from those collections.
Unchanged record checkpoints perform no Sheet or Drive reads. Changed reads
scan sync-state metadata and verify only changed canonical record rows against
their recorded payload hashes. Revision metadata still crosses the network;
this is not a journal/cursor transport or an instantaneous Google RPC guarantee.

The matching broker advertises `brokerRecordDeltaRecordsVersion: 1`; the Script
advertises `recordDeltaRecordsVersion: 1`. Windows requires both capabilities
for ordinary record-only pulls and reports an update requirement instead of
silently falling back to collection downloads. Script, backend and Windows
changes must be deployed together. This source bundle has not been deployed
to a real school by this change.

A new device, or an older installation without per-record checkpoints, needs
one verified baseline. Invalid legacy baselines are retained for explicit
repair instead of being fetched repeatedly. Full inventory verification remains
an explicit `syncNow(verifyInventory: true)` opt-in, not ordinary manual sync.
Direct external edits to Sheets that do not update the revision metadata need
this separate verification; lightweight revision checks do not detect them.
Missing/corrupt sync-state data or mismatched canonical rows fail closed without
advancing manifests. Missing IDs are never inferred to be deletions.

Pause immediately gates admission, publishes the Paused state and stops the
sync animation. An already-sent operation may finish; its durable ACK is still
processed. No unsafe network cancellation, queue clearing or operation-ID reset
is introduced. The independent-device regression now exercises record deltas
through the production local apply path, including edit, reopen and deletion.

Limits retained: 100,000 revision entries per request, 20 MiB record response
and bounded collection batches. This does not establish live 50,000-attendance
throughput, simultaneous physical-PC acceptance or Facebook-like latency.
Drive-account migration is excluded.
