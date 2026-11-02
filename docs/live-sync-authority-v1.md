# Live sync authority v1 — isolated canary implementation

This branch is an experimental implementation, not a production authority
cutover. Existing Windows, student Android and website sync paths are unchanged.
The production broker tombstone fix from PR #205 is retained.

## Implemented

The private, HMAC-authenticated `live` Durable Object lane binds one immutable
school identity. Only an explicitly configured isolated school may enter it.
The broker additionally checks school-admin membership, current licence and
device authorization through its existing request owner.

Supported initial collections: `school_expenses`, `school_calendar`,
`school_notices`, `school_settings`. Students, teachers, fees, attendance and
documents fail closed. Their generation, ownership, reconciliation and document
lifecycles must be ported and tested before admission.

Each changed record commits atomically with a replay event, immutable operation
receipt and backup job. Retry with the same operation ID returns the saved
receipt; changed content under that ID conflicts. Unchanged saves do not create
another event or backup. Writes use exact-revision CAS. Patches change only
supplied fields. Tombstones never silently recreate a deleted record.

Receipts distinguish `cloudState: committed` from `backupState: pending`.
Neither is a legacy protocol-2 Drive ACK. Live and Drive revisions have separate
storage columns; verified backups cannot overwrite a newer live revision.

Cloudflare holds temporary payloads for **24 hours after a verified Drive/Sheets ACK**. The existing school-isolated Durable Object alarm automatically removes the exact backed-up record/event/operation payload copies when the 24-hour deadline passes. A missing, failed, retried, or unverified Google ACK **never** starts the deletion clock, even if the pending request exceeds 24 hours. The current record body is cleared only for the exact matching verified live revision; newer unverified edits cannot be erased. Operation IDs, hashes, revisions, replay cursors, and deletion metadata remain for safe deduplication. A separately authorized rollback may release an already hash-verified Drive copy early after signed full-baseline verification; this is not ordinary TTL cleanup. Verified
seed payloads are also discarded after the initial baseline is sealed.

Point reads of cleaned records use a signed GS point read and verify school,
exact Drive revision and a business-content/deletion hash before projecting the
unchanged live revision. Later edits use that verified baseline inside record
CAS without leaving a permanent Cloudflare cache. A missing, changed or foreign
Drive record fails closed. No Drive row is overwritten by recovery.
An already-connected device can provide its cached baseline for an edit: the
server checks school, exact current live revision and the full content/deletion
hash before using it. This avoids a slow redundant GS read without trusting
client assertions or keeping the payload permanently on Cloudflare. A stale or
changed cached value falls back to verified Drive readback.

Replay events are current-state hints: the broker resolves each affected record
to its newest version, including from Drive after cleanup. It does not attempt
to retrieve obsolete historical row payloads that GS has since overwritten.
This prevents an old replay event from resurrecting an earlier value. Cursor
order and the client's durable retention contract remain unchanged.

An explicit offline create for an existing same-school/key is reconciled only
when its complete business content and deletion state match. The saved cloud
version wins, the original operation identity is retained, and no new event or
backup is produced. Different content remains a conflict. The existing Windows
verified duplicate repair, including linked-child protections, is reused and
covered by an independent-SQLite-device CI regression; it is not replaced by a
name/phone similarity heuristic.

Backup leases fence stale workers. A successor for the same record waits for
its predecessor; an independent record can progress. A failed/ambiguous GS ACK
retains the job. A review failure blocks only that record's dependent backups.
The exact original backup operation ID is retained across retries/restarts.
Cleanup additionally verifies the returned or freshly point-read GS record's
school, revision, operation identity, deletion state and complete business hash.
A successful HTTP response or revision string alone cannot release payloads.

The WebSocket endpoint uses short-lived, school-admin grants issued after
normal broker authorization. The grant goes in a WebSocket subprotocol rather
than the URL. Hibernation attachments preserve the scope and expiry; expired
connections cannot receive later hints. Sockets carry cursor wakeups, not school
record payloads. An authenticated replay request supplies record data.

Replay is ordered and bounded to 100 events / approximately 300 KB per response.
Clients validate contiguous sequence numbers, school identity and revisions.
The shared Dart replay owner serializes pull requests and sends a receiver
receipt only after local durable retention. The Windows adapter stores the
incoming page and cursor in one CAS-protected local transaction; it does not
overwrite pending edits or fabricate upload/Drive receipts.

## Configuration and routes

Default is OFF. No live flag, migration, or authority change is made in production
by this branch. Worker optional `LIVE_SYNC_TEST_SCHOOL_ID` and broker optional
`SAARTHI_LIVE_SYNC_TEST_SCHOOL_ID` must both name the isolated TEST school. The
server environment adapter admits only `vs-db8afb01a3be46a983c8284714d06e5d`.

Authenticated school-admin API, all with `liveProtocol: 1`:

| Action | Purpose |
| --- | --- |
| `managed/live/prepare` | Read signed GS baseline, seed bounded immutable pages, recheck the source head, then seal |
| `managed/live/commit` | Atomic live write/delete/patch; optional verified cached baseline and explicit offline create intent |
| `managed/live/read` | Own-school point read |
| `managed/live/head` | Current sequence and collection admission states |
| `managed/live/changes` | Replay after a saved cursor |
| `managed/live/snapshot` | Bounded baseline pages pinned to an unchanged head; restart if it moves |
| `managed/live/grant` | Short-lived admin WebSocket capability |
| `managed/live/received` | Device-scoped durable receipt |
| `managed/live/stats` | Cloud cursor and separate backup state counts |

`managed/live/drain` accepts only the existing signed Cloudflare callback and
rechecks current school access. Public callers cannot seed pages, claim leases,
finish backup jobs or nominate their own successful backup revision.

## Required before production promotion

1. Freeze legacy writers for each migrated collection with a durable migration
   fence. The baseline head recheck alone cannot prevent a concurrent legacy
   write immediately after verification. Never promote without that fence.
2. Connect the replay owner to each application's existing local conflict/apply
   owner and its durable outbox. The new Windows adapter currently retains
   incoming events; it does not yet apply them to business screens. Android
   student readers need person-scoped projections, not the school-admin feed.
3. Add durable migration abort/resume and verified rollback reconciliation.
   Switching back to GS while backups lag would lose visible live edits.
   Payload cleanup/read fallback is implemented, but automatic cutover of the
   existing business-screen/apply owners still requires this migration fence.
4. Add lifecycle-aware validation and projection for students/teachers, financial
   ledgers and documents, including same-slot generation replacement and media.
5. Add bounded replay compaction, pinned snapshots that tolerate busy writers,
   device receipt expiry and backlog limits suitable for measured scale. The
   current canary retains history and fails closed at its event ceiling.
6. Run actual two-device/offline/process-kill tests, token revocation/expiry,
   unavailable GS, crash/restart between commit and receipt, restore, and measured
   p95 latency/quotas. Local Miniflare timing is not live latency evidence.

Do not relabel Drive-pending operations as fully backed up. Do not deploy this
experimental authority to a real school before the above gates pass.

## Verification

`cloudflare-sync`: `npm ci --ignore-scripts`, copy `.dev.vars.example` to
`.dev.vars`, `npm run types`, `npm run check`, `npm run build`, `npm test`.
`functions`: `npm install --ignore-scripts --no-package-lock`, `npm test`.
Pure Dart replay checks: `dart .github/tests/live_sync_protocol.dart`.
Windows adapter: `flutter test test/windows_live_sync_store_test.dart`.
CI extends the existing Cloudflare review workflow with both client checks.

### Durable migration admission

The broker now persists per-school migration state and legacy request markers in
`school_live_migrations`. Preparation closes admission before examining existing
writers, waits a two-minute deployment drain grace, requires both legacy record
and notice queues to have zero pending and zero review jobs, and only marks a
collection active after verified seeding. Live commits require that active state.
Legacy writes to an active collection fail closed; local outboxes must retain
those requests. Broad batch/restore actions are fenced across collections.

Markers deliberately have no timeout expiry: a timed-out Google request may
still complete. Failed/uncertain requests or a crashed broker therefore require
operator investigation before migration; retrying preparation cannot clear them.
Successful requests remove their own marker. Rollout must replace every old
broker instance before beginning the grace period; an older deployment cannot
participate in this admission protocol. This is a safety gate, not completed
business-screen routing or an automatic rollback implementation. Live schools
remain disabled in production pending those integrations.

### Business gateway and verified rollback integration

The existing admin record API negotiates live protocol 1 for activated
collections. Full/point reads, changed-record delta checkpoints and mixed batches
route through the same four-collection authority, retaining explicit
`cloudState` and `backupState`. Unnegotiated older clients fail closed. Collection
heads are independent so a notice does not invalidate the expense checkpoint.
Windows retains its existing outbox owner, checks canonical live receipts,
forwards only an exact durable baseline, and never uses temporary revisions as
verified Sheet-repair evidence. Android school notices use the live source only
after normal signed person-session authorization; other person projections keep
their existing lifecycle owner. Internal authenticated legacy delivery bypasses
the user migration fence so already accepted work can actually drain.

Rollback closes durable live admission before checking every current record and
tombstone against signed Drive point reads. The Worker seals only an unchanged
metadata fingerprint/head with zero unverified backup jobs and zero resident
record payloads. Both Worker sealing and the broker transition are retryable
after a crash. A failed or uncertain proof leaves the collection frozen and
preserves all data. Old live-version outboxes after rollback require verified
reconciliation; their revisions are never silently rewritten.

Admission remains limited to independent administrative records. Student
cascades, financial operations, attendance and file lifecycle owners cannot be
replaced by generic record CAS. See `live-sync-lifecycle-review.md` for the
contracts and tests. Production flags remain off. Physical-device, large-load
latency, scalable history compaction and full lifecycle admission remain release
gates; local tests are not evidence of production rollout.

Rollback routes notices directly to verified school Drive rather than reviving
an obsolete legacy notice cache. Global live replay emits strict, payload-free
Drive retirement invalidations for sealed collections, allowing other active
collections to keep advancing. Receivers durably retain that retirement marker
with the cursor, without inventing a business record or upload acknowledgement.
Mobile person operations do not consume migration admission markers because
they cannot mutate any admitted administrative collection.

### Durable runtime, domain handoff and lifecycle additions

The Windows replay runtime now runs inside the existing serial sync owner. It
uses existing authenticated, pending-aware business reads/applies, closes on
pause/profile changes, and retains blocked pages without a hot loop. Verified
prefix compaction preserves monotonic global/collection cursors and immutable
operation receipts. An expired replay cursor receives LIVE_SNAPSHOT_REQUIRED;
only a verified stable snapshot can replace that local checkpoint atomically.

Uncertain request markers now bind immutable operation hashes. Positive Worker
receipts or exact signed GS operation/request hashes can reconcile them. Same
operation retries reuse their marker instead of filling the admission limit.
No timeout or missing receipt is treated as proof of failure.

The canary person coordinator journals hashes and retirement manifests, fences
parent generations and verifies student/teacher cascades against signed GS.
Bundle2026-11-02.1 adds generation-bound teacher retirement, access revocation,
shared-file protection and staff inactive retirement while preserving salary
and attendance history. New destructive operations require advertised deployed
GS capabilities. Embedded staff payroll retains a separate GS owner; settings
snapshots merge it with a composite head rather than making it a generic row.

Financial, attendance and exam staged intentions have an explicit tentative
projection; they cannot become canonical totals, business rows or fake Drive
ACKs. Canonical domain results remain signed-GS verified. Opt-in records-spool
cleanup removes original requests and canonical response bodies only after full
content/patch/delete proof, retaining exact source hashes for Drive hydration.
Attendance cleanup retains only a scoped ownership receipt, and retired legacy
notice caches are erased only after a verified live baseline with no pending
legacy jobs. File bytes retain their existing verified-Drive cleanup owner.

Deployment is a separate acceptance gate: new source code does not update a
school's existing Apps Script /exec deployment. Real remote latency/capacity,
physical 1/2/5-device acceptance and activating production flags are not proven
by local tests. Tentative domain proposals are not instant authoritative commits.

### 24-hour verified cache lifecycle

For all-data record spools and resumable file chunks, a completed proof-backed Drive handoff starts a 24-hour temporary payload retention clock. The existing Durable Object alarm schedules the expiry; retries, partial uploads and blocked items are never time-deleted. Older completed entries already purged remain purged (no recreated bytes). Legacy school notices and attendance have separate person/privacy owners and retain their verified sanitization controls; these are not converted into unrestricted raw PII caches by this change. Cloudflare metadata persists after payload deletion for safe exact-operation replay. Live authority stays Draft/OFF for production until school Apps Script and device acceptance pass.
