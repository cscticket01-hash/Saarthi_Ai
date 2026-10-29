# Safe sync performance upgrade

Baseline: main `f256e075`, Windows 2.1.197. This change preserves Google Drive/Sheets as authoritative. Cloudflare acceptance is still staging, never a permanent record/file ACK. No existing school, queue, operation identity or Script property is reset.

## Implemented changes

- Incorporate the existing PR #169 Sheet optimization: reuse only the current locked operation's row lookup; re-read the exact old row before overwrite; retain a fresh post-flush duplicate search and exact saved-data verification. Normal non-partitioned lookup calls fall from three to two. Signed health identifies this candidate as `scriptBundleVersion:2026-10-29.1` and `recordLookupReuseVersion:1`. JSON and partitioned stores keep their prior paths.
- Defer automatic ID PDF rendering until cloud owner/revision evidence has been checked. An existing matching cloud card or protected input mismatch needs zero new render calls. Conflict retention reuses the same point-read future and validates school, owner, hash and revision through the original CAS owner. It no longer scans all reviews and reads a full documents inventory for each newly discovered mismatch. New or deliberately edited local cards still use the same renderer, durable outbox and verified publication path.
- Add resource-aware scheduling inside the existing school record spool. Unrelated expenses/attendance keys can proceed while another key waits for retry. All earlier operations touching the same key remain ordering dependencies. Legacy rows and person, document, fee/payment, backup or unknown dependencies remain conservative school-lane barriers. Dedicated notices retain their separate existing FIFO lane.
- Optional parallel drain is exactly two eligible record jobs. Broker default stays one; `SAARTHI_EDGE_RECORD_PARALLELISM=2` is an isolated canary setting, not a client setting. The broker requires `recordSchedulingVersion:1` before requesting two jobs. Old Workers fall back to one. Every claim rechecks dependencies. Partial batch receipts, provider backoff, original IDs and exact Drive ACK verification remain mandatory.
- Add session-local p50/p95/p99 and sample counts for record ACK, Script round trip, Cloudflare queue/delivery and upload/card/repair/download stages. Failed stage durations are separate. Each distribution retains at most 256 observations and is cleared with the school profile. Durations overlap; they are not additive. The panel shows no invented timings before samples exist.
- Extend the arithmetic capacity tool to distinguish Firestore and Cloudflare attendance queues, one/two daily events, one/five PCs, and burst admission requirements. Cloudflare mode removes only Firestore attendance queue lifecycle writes. Authentication, licence, business data, hints, provider quotas and Google replication still require separate budgets. Existing realtime delta/feed and missed-event replay mechanisms are reused.

## Safety and release checks

The SQLite spool adds nullable resource metadata and a creation timestamp without rewriting existing payloads. Legacy resource metadata is a barrier until its original job resolves. Claim fences, duplicate admission, hash validation, partial receipts and school namespaces remain intact. Terminal or failed operations never become a successful ACK merely because another job finishes.

Required regression coverage includes: no PDF render on cloud mismatch/match; one scoped cloud read on mismatch recovery; source-file/outbox retention; profile switch; retry head bypass; same-record claim rejection; person/document/payment and mixed-batch barriers; two-job concurrency ceiling; old-Worker fallback; fake/foreign ACK rejection; failed partial-batch replay; owner and school isolation; SQLite restart/CAS and UI regressions.

Run `.github/scripts/sync3_capacity_budget.cjs` for planning scenarios. Firestore daily free quotas and Apps Script execution/account limits were checked on 2026-10-29 against:

- https://firebase.google.com/docs/firestore/quotas
- https://developers.google.com/apps-script/guides/services/quotas

These scenarios are not measured provider throughput. The 400-school fixture is synthetic; neither it nor two-job local runtime tests certify 100,000 simultaneous production operations. Do not increase concurrency to compensate for a shared Google quota or lock bottleneck.

## Deployment and measurements still required

The school-owned Apps Script must receive the compatible optimized bundle before the Sheet speed change can apply; a Windows release cannot update a privately owned Script. Keep the existing school ID, root, secret, properties and deployment URL. Verify in the isolated TEST school before real-school promotion. A fresh before/after wall-clock benchmark is required to claim seconds saved.

Worker rollout precedes optional two-job broker rollout; deploy the broker serially first. Existing jobs survive a rollback because legacy/unknown dependencies remain serial. New native app code requires a Windows update; shared signed rules cannot invent this new native behavior. School data stays isolated, and all server-authoritative licence/device checks remain enabled.

Physical Android background/battery recovery and 1/2/5-PC hardware acceptance require actual devices. An authoritative Cloudflare database migration, automatic approval of new repair code and unconstrained parallel writes are outside this upgrade.
