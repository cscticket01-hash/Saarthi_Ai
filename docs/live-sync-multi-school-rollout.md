# Explicit multi-school live sync admission

The broker's fixed TEST-only selection and the Worker's one-school equality
checks are replaced by explicit school allowlists. Up to 400 distinct school IDs
are supported. Defaults remain off. This change does not migrate or certify any
school and does not turn a staged/Drive-pending operation into a Drive ACK.

Set `SAARTHI_LIVE_SYNC_SCHOOLS` on the existing broker and `LIVE_SYNC_SCHOOLS`
on the matching Worker to the same comma-separated canonical school IDs.
Whitespace is trimmed and duplicates removed. Wildcards, malformed IDs and
lists above 400 schools are refused. Existing isolated TEST bindings still work.
The existing edge delivery school allowlist must also admit each selected ID.
Apply provider limits when splitting large lists across deployment cohorts;
never truncate a list silently or substitute `*` for rejected configuration.

School IDs in these lists only enable protocol admission. Existing per-school
authentication, licence/device checks, Durable Object identities, migration
fences, source-head rechecks, exact-revision CAS and verified Drive backup
requirements still apply. One school's baseline never activates another school.

An authenticated school-admin can call `managed/live/rollout-status` to inspect
only their own scope. It reports broker/Worker agreement, deployed GS
capabilities, actual legacy records/notices backlog, uncertain request counts
and collection migration states. It creates no migration, clears no queue and
does not expose school records or secrets. Unknown/unavailable queue state is
`null`, never a fabricated zero. `fullRolloutVerified` remains false: this API
cannot certify installed clients, person-scoped mobile projections, device
acceptance or measured end-to-end latency.

Before production activation, update the EXISTING school GS deployment while
preserving Script Properties/root/workbook/secret, verify current client protocol
and capture a verified school backup. Replace every old broker writer before
the durable migration drain grace begins. Reconcile uncertain operations from
positive receipts; never erase their markers. Drain and verify legacy queues,
then use the existing authenticated preparation owner for admitted independent
collections. Native student/teacher/document/financial dependencies require the
existing complete cohort fence and lifecycle acceptance; allowlisting alone is
not that cohort migration. Native-cohort rollback and field/load acceptance are
separate outstanding promotion gates, not supplied by this configuration change.

Verify record add/edit/delete on the installed clients, receiver visibility
before Drive ACK, separate durable ACK, offline recovery and school isolation.
Widen only after retained baseline, backup and receiver reconciliation evidence.
Do not report all schools live from a source merge, allowlist or successful build.
