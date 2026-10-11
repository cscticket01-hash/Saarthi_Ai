# Universal Self-Healing Engine 2.0 — release review evidence

Development starts at main `cd02207127cc2b6dd360c63bc0661a0bd2d5dbcb`. Branch: `feature/universal-self-healing-2`. Draft PR: https://github.com/cscticket01-hash/Saarthi_Ai/pull/30. One coding agent performed this task. No main merge, production deployment, release publication, live Firebase configuration or rules change is authorized or performed.

## Availability boundary

This is an independent in-process health supervisor. The school app does not depend on guardian success to start or complete its business operations. It cannot restart a terminated application, run on a powered-off PC, override Android background restrictions, restore an unavailable hosting provider or guarantee 24/7 availability. Physical Windows/Android soak testing, process supervision and hosting availability remain separate acceptance requirements. It is unsafe to make this draft the sole basis of a 24/7 production claim.

## Implemented behavior

The version-2 provider contract registers independently owned engines. The default bounds are 32 providers, two concurrent checks, one active repair, 128 retained events, 512 deduplication keys and 16 latency samples per provider. Timed-out work remains locked per component until the actual underlying future settles. Independent components can continue after quarantine. Heartbeat checks use 30-second monitoring and a 90-second watchdog; no polling can run while the process/event loop is suspended.

Healthy status requires an actual verification timestamp from the last five minutes. Unknown is explicit. School/profile binding and a generation guard invalidate old in-flight work, including A→B→A switches. Failure classification uses typed signals, never uploaded raw exception messages. Dependency admission requires recent verified health.

Only deterministic source-reviewed playbooks can execute. Every admission is saved and read back before the action. Cooldown and the rolling circuit budget survive restart. Observation deduplication and bounded history trimming preserve recent admissions. Malformed, unreadable, oversized, interrupted or future-clock history disables repairs and is preserved rather than silently rewritten. Guardian metadata is separate from school database/backups. File-copy readback is not a claim of atomic filesystem durability across every hardware failure.

### Automatic playbooks actually installed

| Playbook | Action and verified scope | Limits |
|---|---|---|
| `refresh-sync-view` (Windows) | Existing Smart Sync `refreshDetails()` rebuilds the display projection; same school, no sync in progress, projection available afterwards | 2 admissions/hour, increasing 1-minute cooldown, 5-second deadline |
| `restart-monitor-timer` | Recreates the guardian's diagnostic timer; verifies an actual new event-loop heartbeat | Same bounded admission policy |

The guardian does not retry business submissions independently, clear queues, alter operation IDs, manufacture ACKs, reopen live SQLite connections, reset databases, resolve conflicts, reissue QR credentials, change licensing or bypass App Lock. Smart Sync's existing authorized recovery remains its responsibility. Document decoding/rendering faults are observed and escalated; there is no generic retained-original decoder retry playbook in this draft.

### Provider evidence

| Provider | Evidence available in this implementation | Boundaries |
|---|---|---|
| startup | Actual adapter startup completion | Does not certify every security gate or future startup |
| database | Existing Windows local-storage health timestamps | No new continuous SQLite scans or live-lock repair |
| smart-sync | Owner state, pending counts, typed recovery classification, last successful sync | Owner retains retries, queue and ACK verification |
| sync-view | Existing queue display projection | Display availability does not prove cloud completeness |
| id-card | Actual individual and bulk render outcomes | Rendering does not certify printing or all resume paths |
| qr | Actual shared parser outcome | Parse success does not grant server authorization or certify camera health |
| inventory | Actual student-document bridge operations | Successful list/save does not prove integrity of every attachment |
| documents | Actual image/PDF pipeline outcome and processing latency | Preserves source processing behavior; no guardian resubmission |
| attendance | Android owner readiness/failure/pending status | Pending count alone never marks healthy or acknowledged |
| notices | Verified same-school notice response after durable cache commit | No guardian ownership of notice records |
| monitor-worker | Actual timer heartbeat | In-process watchdog only |

Windows shows a compact expandable panel inside the existing Sync & Backup Control Center, after established navigation/content. Android has a hidden lifecycle observer and widget lifetime cleanup; context polling/reporting pause in the background. No new mobile page, foreground service or permission is introduced.

Developer monitoring uses the existing authenticated developer role and exact school scope. Strict schema/enum allowlists exclude names, photos, documents, tokens, paths, operation IDs and stacks. Reporting coalesces one pending diagnostic snapshot, sends at most every five minutes with bounded failure backoff, and keeps a timed-out request locked until its actual future settles. Missing existing mobile authorization skips reporting without forcing login/renewal. Server-side per-installation and principal budgets limit writes.

The command center currently summarizes a selected school, caps complete summaries at 200 installations and returns Unknown on overflow. Report expiry is seven days in application reads; physical Firestore TTL deletion is not configured by this task. There is no cross-school global dashboard, historical release-regression model, remote-command system or global incident paging.

Predictive warnings use at least eight real latency observations, compare rolling samples and explicitly label the result an uncalibrated heuristic. Diagnostic fingerprints group component/version/category/stage; bounded histories support recurrence and observed repair effectiveness. Correlation with a database failure is a possible shared cause, never a proven root cause. Optional AI advice accepts only sanitized metadata and returns bounded untrusted text. No external AI provider is configured; advice cannot execute repairs or code.

## Verification and performance

Exact CI results and benchmark values must be appended after the final implementation commit finishes. Previous-commit passes do not certify changed source. Fault injection, actual SQLite fixture tests, hosted builds and physical acceptance are reported separately.

`test/universal_health_test.dart` verifies admission, persistence, forbidden retry classes, false-success prevention, quarantine, cooldown, circuit recurrence, school switching, admission retention, future-clock preservation, future registration, bounded flood, prediction gating, advisory authority boundaries and a real SQLite/media preservation fixture. Existing Smart Sync, QR, ID-card, documents, mobile attendance, startup, security and backend suites run alongside it.

`tool/health_benchmark.dart` measures a 100,000-observation synthetic flood, process CPU ticks, incremental process RSS, a verified no-business-write fixture repair, a 31-second hosted idle monitoring sample, serialized history and bounded queue size. Hosted Linux process CPU includes runtime/measurement overhead and shared-runner noise. It is not representative desktop/mobile acceptance. UI-thread impact, physical startup impact, typical-device incremental memory and heavy student workload impact remain unmeasured until exercised on representative hardware. Targets below 1% idle CPU, below 30 MB typical incremental memory and below 16 ms UI blocking are acceptance targets, not promises.

Before release: require final exact-source checks, representative Windows and Android lifecycle/soak tests, privacy-safe retention configuration, real installation reporting verification and workload/latency measurements. Further automatic repairs require an owner-supported safe interface and separate reviewed tests; unsupported repairs remain Needs Attention. Keep this PR draft until these limitations are accepted or resolved.

## Measured completed run (predecessor implementation)

At source `f2839f67361019e7f472f381cb0b8c6719c04330`, guardian run https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38168744744 passed strict analysis, 142 Flutter regression tests (including 37 guardian tests), the actual benchmark and 376 backend tests. A later reporting-cooldown change and two tests require final-source rerun; predecessor results are not substituted for it.

The 100,000-observation hosted flood completed in 138,683 µs (721,069 observations/second), retained 3 events / 492 serialized bytes and deduplicated 99,999 observations. The no-business-write repair plus verification took 5,280 µs. Own-process active CPU measured 173.06% (includes multicore VM/runtime work). The 31,001 ms idle sample observed 0 CPU ticks of increase, reported as 0.0%; this short, tick-resolution sample does not certify representative desktop acceptance. RSS changed by −55,562,240 bytes, consistent with process/runtime reclamation and therefore insufficient to establish positive incremental monitoring memory. UI blocking, real startup and heavy-record workload overhead remain unknown. Artifact: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/38168744744/artifacts/11713430250 (expires 2026-10-25).

Local full backend execution also passed 376/376 after installing existing function dependencies with lifecycle scripts disabled. An initial local run from the repository root used the wrong relative fixture paths; a subsequent run required the existing firebase-admin dependency. These setup failures are not hidden or counted as passing runs.

## Requested scenario coverage boundaries

| Requested scenarios | Automated evidence / unresolved acceptance |
|---|---|
| 1, 3–5, 8–14, 28–30, 32 | Guardian fault tests: verification freshness, typed failures, forbidden retry classes, deduplication, actual underlying locks, persisted circuit, school switch, isolation, future registration, prediction gate and history persistence |
| 2, 33–34 | Existing Windows startup, local-first Smart Sync, SQLite, App Lock and owner regression suites; final platform run required |
| 6 | Database lock faults do not grant an arbitrary reset/reopen. Owner SQLite atomicity/crash tests remain separate; no new automatic live database-lock repair is claimed |
| 7, 24 | Monitor timer watchdog and Android lifecycle/lifetime implementation; representative interrupted-worker/device lifecycle soak remains outstanding |
| 15–19 | Actual SQLite fixture and original-media comparison plus queue/operation preservation regressions; simulated fixtures do not prove every possible hardware failure lossless |
| 20–21 | Real existing document processing regressions and observed image/PDF pipeline; no generic autonomous original-image decoder retry playbook |
| 22–23, 35 | Actual ID render/bulk and QR parse adapters; existing ID-card, QR/mobile login and Android regressions. Physical camera/printing compatibility remains unverified |
| 25–27 | Real Windows control-center regression suites, authenticated developer endpoint tests and strict telemetry sanitization; real deployment end-to-end reporting remains a release check |
| 31 | Measured synthetic 100,000-event flood and bounded history; physical heavy-school workload overhead remains unknown |

The numbering maps to the requested 35 scenarios; it is not a 35/35 pass claim. The implementation contains two approved automatic repair classes, not an unrestricted recovery library. Unsupported business repairs require a reviewed owner interface, original-operation admission and outcome proof before expansion.

## Network reporting recovery correction

Owner diagnostic HTTP clients can throw SocketException or ClientException before receiving an HTTP response. Both platform adapters previously treated those exceptions as permanent attention, blocking reporting for the current school after a temporary outage. They now classify only timeout/socket/HTTP-client transport exceptions as retryable, using the existing bounded reporter cooldown and single pending snapshot. HTTP authorization/conflict handling and unknown exceptions remain attention; no login renewal, business retry or queue ACK is added. Added typed classification tests and a reporter outage-to-accepted regression preserving the pending snapshot until acceptance. Hosted final-source Flutter verification is required. Local unchanged backend suite: 377/377 PASS.
