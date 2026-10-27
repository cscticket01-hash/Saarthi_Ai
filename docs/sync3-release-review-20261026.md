# Sync Engine 3 release review — 26 October 2026

This review covers PR #135 only. It is not production approval. Production merge, website/installer publication and production Render/Script changes remain prohibited until the owner approves the concrete release.

## Release decision

Keep DRAFT while the current Android native acceptance, capacity and measurement gates are unresolved. A green compilation job is not a native synchronization result. Hosted/emulator evidence does not certify physical PCs, phone battery policy or a real network outage.

The current shared free Firestore allowances do not cover the documented 400-school attendance/polling scenarios. See `sync3-provider-capacity-20261026.md`. No billing change or quota exhaustion is authorized by this review. The actual project plan/quota usage and representative provider throughput must be established before promising that workload.

## Existing evidence to preserve

- Exact baseline `e08ce5b51901f268384ff50d76c642caa1fa4fe9`: code/build, security, 1/2/5 independent SQLite PC fixtures and 400-school synthetic correctness workflows passed. Do not repeat the large synthetic test merely to claim real-provider capacity.
- Windows and website stages of the isolated native chain have passed previously. The Android DDS startup failure is an infrastructure failure, not a successful Android test. A replacement run must preserve native SQLite, secure-storage, cloud ACK, duplicate-attendance lock and Android-to-Windows readback assertions.
- Native Drive upload continuation, exact downloaded hash and retained upload-key evidence are already recorded in the handoff. Do not delete its fixture or journals to obtain a clean test.
- Real latency reports must identify the source, sample unit, cohort correlation, failures/timeouts, environment and applied-receiver boundary. A single sample, median API time or synthetic timer is not a production p99.

## Physical acceptance matrix

| Case | Available evidence | Physical status |
|---|---|---|
| One, two and five Windows PCs | Hosted independent SQLite caches, original operation IDs, conflict/no-op/reconnection regressions | Hardware unavailable; not certified |
| Android offline and restart | Hosted native/emulator acceptance must be checked on the final source | Physical phone unavailable; not certified |
| Android background, force-stop, reboot and battery policy | Deterministic cache/queue ownership tests and existing worker integration | Physical OS behavior not certified |
| Genuine network disconnect/reconnect | Controlled transport faults and provider prefix continuation | Physical network loss not certified |

Hardware execution must compare unchanged original operation IDs, local pending work and remote verified receipts before and after each interruption. Never clear a queue, manufacture an ACK or replace a school identity to make a check pass.

## Rollback inventory (read-only observation)

Observed production broker rollback baseline: service `srv-db06j2id0e5s73aafdi0`, LIVE deploy `dep-dbf5k4tg1s2s73eij25g`, source `533c49d0a9abb9abf67fc05894e3ba9d42549490`. Its message identifies the reviewed main `9c1cacd` broker and Windows v2.1.177 download fallback. Re-read this state immediately before any approved rollout; another release can supersede this observation. No rollback or production mutation was executed.

Record the exact approved forward source, previous live deploy/source, existing Script version/URL and immutable installer manifests/hashes. Keep credentials and private provider sessions out of reports. Do not infer that rolling back Render restores Firestore, Drive, Sheets or local queues: it does not.

## Compatibility and safe rollback boundary

The new upload protocol requires both broker and Script capability flags; existing small/full-upload and opt-out paths remain. The new encrypted Android cache is an internal client store with account/version fencing. Existing signed school identity, revision CAS, tombstones and attendance policy remain mandatory.

Capability negotiation alone is insufficient for an in-flight rollback. A client can recheck capabilities after restart, while the Script retains a private native upload session. An old broker/full-upload writer must not be introduced for that uncertain operation. Before rollback, inventory admitted native uploads and durable pending work without exposing private session URLs. Finish/resume them with the compatible owner or retain the forward-compatible broker until a reviewed recovery path is available. Preserve every `VS_UPLOAD_SESSION_*` journal, original upload key and preallocated file ID. Do not flip native upload off mid-flight or clear journals to pass this gate.

Do not downgrade the Script to a version that cannot understand current authoritative heads, deleted student generations or retained tombstones. Do not migrate, reset or replace school storage during rollout. A failed deployment should retain the prior healthy instance; an uncertain mutation still requires normal receipt/status reconciliation, never blind replay.

## Concrete approval package

Before asking for production approval, attach: final PR SHA and exact-source CI results; native Android-to-cloud-to-Windows proof; scoped latency distributions; provider budget and unresolved hardware/load limits; selected production forward/rollback sources and installer hashes; and the in-flight-operation compatibility check. If a gate is unavailable or fails, state it explicitly and keep the production decision blocked. Do not represent this runbook as an executed rollback rehearsal or a 400-school certification.
