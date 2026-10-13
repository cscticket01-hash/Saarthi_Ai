# Self-Healing 2.1 autonomous infrastructure repair

Resumed `859c3a0` on the existing PR #48. The original 1,000 IDs and 974 distinct source messages are preserved. This change adds executable recovery, not more diagnostic entries. The machine-readable evaluation of every ID is [self-healing-autonomous-coverage.csv](self-healing-autonomous-coverage.csv). A CI artifact regenerates the same table with verification status after the dedicated repair fault suite passes.

## Implemented capability boundary

| Registered executable ID | Actual owner and recovery | Independent success evidence |
|---|---|---|
| refresh-sync-view | Existing Sync-derived display refresh | Owner-derived projection available; no queue mutation |
| restart-monitor-timer | Existing supervisor heartbeat recovery | Fresh heartbeat under the same lease |
| restore-owner-timer | Existing reconciliation/report cadence recovery | Expected missing owner timer restored |
| restore-admitted-dispatch | **New**, Smart Sync dispatch owner | Captured scheduled deadline restored exactly once; no immediate call to syncNow, retry admission or deadline advancement |
| restore-checkpoint-deadline | **New**, Smart Sync scheduling owner | Already existing future checkpoint anchor retained; other timers/checkpoints unchanged |
| restore-health-delivery | **New**, diagnostic report owner | Correct scoped retry timer matches the persisted due time; actual report acceptance remains separate evidence |
| restore-context-observer | **New**, Android lifecycle owner | Foreground enabled same-school/person observation timer restored; no attendance/business retry |
| restart-owned-image-worker | **New**, fixed pure image-processing owner | Actual owned-isolate exit; private original retained; one retry; matching input fingerprint, valid output containers/dimensions and current lease; completed derived result |

There are eight unique executable IDs: three existing and five new. Windows registers eight playbook instances (the generic timer ID is used by two owners); Android registers five. Platform registrations overlap and are not summed into a unique total.

Direct catalog coverage rises from four infrastructure patterns to **six conditional infrastructure patterns**. Four existing Smart Sync transport patterns remain **owner-mediated**: network path, deadline, server and quota. Their data-retry implementation already existed and is not claimed as new. The conditional union is **10 of 1,000**, not ten unconditional fixes or ten proven original-school resolutions. Missing dispatch/checkpoint/delivery/lifecycle conditions can also use the executable providers without adding or inflating catalog IDs.

The other 990 patterns stay manual/unavailable. Most are source validation, identity, authorization, integrity or business-intent guards, not restartable infrastructure. A source literal alone does not prove a root cause. No generic unknown exception, forbidden state or knowledge text can register an executable command.

## Safety and scheduling

Every guardian recovery uses the existing scope/lease, registered capabilities, durable admission history, dependency checks, timeout quarantine, cooldown and component circuit. The new Sync APIs restore only an owner's **already-admitted local timer**. They recheck initialized/enabled, current school/profile, pause/reset/block and in-flight state. They neither choose records nor call syncNow, reset backoff, reopen attention queues, mutate revisions or write checkpoints. Sync's normal dispatch still exclusively admits data work and verifies operation identity, receipt/revision/readback.

Diagnostic delivery is separate from school-data synchronization. Its scope-keyed backoff and authorization latch survive restart. Corrupt/invalid persisted admission stays Needs Attention; permission failures never cause an auth reset. A hanging request/preferences future retains the serial send lock. Missing retry timers can be repaired only after settlement, with the current due time preserved. A timer proof does not claim connectivity or delivery success. Actual accepted responses are independent delivery evidence. New aggregate component identifiers are accepted by the existing server telemetry allowlist; no remote commands or record payloads are added.

Image recovery is restricted to the application's own fixed pure isolate function. It cannot access paths, uploads, network or school-record writers. PDF/native printing and invalid media are not restarted. Owned work has a 20s execution deadline, 2s exit proof deadline, two concurrent workers, eight pending calls and a 100MiB admitted-source bound, plus at most one retained failed input (up to the existing 50MiB source limit) and one derived result. An uncooperative exit keeps its slot/quarantine and blocks duplicate work. Recovery is limited to one restart per retained task and the guardian's persisted limits. Requests with the same identity coalesce even during repair. If the original request is still waiting, a successful authorized repair completes it once; otherwise only a verified derived cache is repaired for a later owner request. No upload or original document completion is fabricated.

The pipeline now owns its input/cache snapshot and returns independent byte/map copies. This fixes a confirmed defect where a caller could corrupt subsequent cached results by mutating the returned result. Cache identity includes the current diagnostic scope. Image output verification uses an independently checked input fingerprint, complete container checks and decoded-header dimensions. Scope changes/expired leases reject late repair results before cache commit. Restart does not replay private image input: an unfinished durable admission remains quarantined until fresh owner proof.

## Learning and reported failures

Audits retain optional bounded duration and catalog IDs without raw messages/paths/credentials. Legacy events remain readable. Verified success and same-version/failure recurrence are counted separately; recurrence penalizes preference. Timing uses Stopwatch and cannot grant authority or relax attempts, cooldowns or circuits. Unattributed, wrong-version, wrong-failure, late or duplicate terminal events cannot manufacture successful learning.

The existing typed 45s full-response deadline is preserved. Headers/body stages remain available to diagnostics. No deadline increase, network bypass or speculative production restart is performed. HTTP 502/503/504 and Script/Drive/Sheets retries remain the existing Smart Sync owner's responsibility; restoring a missing dispatch assists that owner but does not prove the provider root cause is resolved.

PR #44 was reviewed. Its conflict verification progress/error placement and widget regression are applied to the current file; this branch's typed full-response transport implementation remains intact. Failed Verify Cloud Version errors stay above the scrollable payload, comparison/selection are reset on retry, and reads have a deadline. Conflict versions and resolution authority are unchanged. Run Diagnostics retains its existing bounded all-provider sweep; it does not itself admit business retries. Monitor history distinguishes Observed, blocked and actually verified outcomes, and reports registered capabilities instead of describing all events as Detection Only.

## Evidence and remaining blockers

See the PR's exact-source CI links for final test counts/results. Dedicated fault fixtures cover real isolate output, automatic same-request recovery, crashes/timeouts, exit quarantine, wrong source/output, stale school results, pause/cross-school denial, coalescing, original/cache preservation, timer deadlines, failed verification, restart budgets and learning. No real-school destructive injection is used.

Original-school 502/slow-sync root cause lacks matched live request/stage evidence. Native/PDF hangs, broken storage/permissions, unsupported owner interfaces and business conflicts remain manual. Physical Windows/Android/five-PC acceptance, representative load and continuous 24h soak are not certified by hosted CI. No main merge, production server/Script/Firebase change, billing enablement or Windows/Android publication is performed.

## Resume verification correction

The first expanded-source CI stopped at a Dart initializer error: a class type
was used instead of its constructor tear-off. The `.new` fix is committed. Its
next guardian run passed 1,217 regressions, 27 dedicated fault tests, both
100,000-observation benchmarks and backend checks; these are prior-source
evidence for the follow-up changes below, not final acceptance.

Checkpoint restoration now also accepts an elapsed **already captured**
deadline. It restores one immediate owner dispatch without invoking `syncNow`,
advancing retry budgets or modifying a queue. Stop clears the anchor. A
deterministic fixture checks the elapsed deadline, duplicate recovery,
reconciliation preservation and one dispatch.

Coalesced image requests share one worker but receive independent result maps
and byte arrays. One consumer can no longer corrupt another consumer's result.
The private derived cache and original input remain protected.

Coverage verification now reads completed Flutter machine test events from the
current checkout, including the owner policy and durable admission suites. A
success banner, unrelated tests, a skipped/failed/incomplete case, missing suite
or old source cannot certify a repair. Each action needs its named fault and
negative fixtures. `refresh-sync-view` now has a dedicated production-provider fixture that
rebuilds the real local projection while preserving the synthetic queue,
refuses stale scope/pause and does not initialize cloud transport.
The CSV includes every case's source pointer/error, root-cause uncertainty,
execution permissions, preconditions, timeout, cooldown, attempts and containment.
It preserves the 1,000 existing IDs and never treats source matching as a proven
runtime root cause. No additional automatic catalog coverage is claimed for
these contract fixes. Final verified numbers come from the new CI artifact.
