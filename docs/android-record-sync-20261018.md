# Android dashboard delta and pause

Android requests `mobileRecordDeltaVersion: 1` with per-list record hashes.
The matching managed Script filters data for the authenticated pupil/teacher
before returning only changed list rows and the complete visible ID list.
The client merges retained rows, acknowledges removals and refuses incomplete
baselines or duplicate identities without advancing its durable cache. This
covers calendar, exam results, fees, payments, fee structures, salary, document
metadata and notices. Profile/settings objects remain versioned groups.

A previous cache without record hashes needs one baseline for that group.
Changed groups still require server-side scoped inventory reads to establish
visibility and removals; this is not the Windows canonical-row-only read path.
PDF bytes remain separately fetched by verified version/hash. Older Script
versions retain their existing group-level transport until the owner deploys
the matching bundle. No physical phone latency claim follows from these tests.

Pause updates the UI and admission gate synchronously before saving the setting
in the existing secure school session. Background attendance workers restore
that setting. Already-sent operations may finish and their ACKs remain durable;
new captures are retained locally while paused. Resume requests a fresh delta.
A lightweight local minute tick checks whether one hour has elapsed since the
last successful dashboard verification; no request/animation is started before
it is due. Push hints, foreground resume and manual refresh bypass the idle
time gate, while pause blocks all of them. Android background WorkManager
attendance reconciliation retains its existing OS-controlled 15-minute schedule.

Wire limits: 1000 visible record checkpoints and 200000 checkpoint characters;
oversized checkpoints fail explicitly and preserve cache. The broker admits
220000 characters only for the dashboard action; other action limits remain.
School identity, role filtering, licence checks and final attendance ACK checks
remain unchanged. Drive account migration remains excluded.
