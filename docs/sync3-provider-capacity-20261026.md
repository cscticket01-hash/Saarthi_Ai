# Sync Engine 3 provider capacity review — 26 October 2026

Scope: source `e08ce5b51901f268384ff50d76c642caa1fa4fe9`, existing isolated TEST service, current official provider documentation. Read-only inspection and arithmetic only: no new schools, bulk fixtures, quota exhaustion, billing changes or synthetic 400-school rerun. This is a capacity assessment, not provider acceptance or a production SLA.

## Decision supported by evidence

The retained synthetic 400-school/100,000-record correctness result does not establish real 400-school throughput. Current central Firestore access patterns exceed the shared free daily allowance under ordinary stated scenarios below. Low CPU in a single TEST school cannot overturn those bounds. Real 400-school concurrent capacity remains **UNVERIFIED**; keeping every feature within free quotas is not established.

## Shared Firestore budget

Official free allowance is 50,000 document reads and 20,000 writes daily, one free database per project; 1 GiB storage and 10 GiB/month outbound transfer also apply. Daily quotas reset around midnight Pacific time. These allowances are central-project totals, not an allowance per school. [Official usage/limits](https://firebase.google.com/docs/firestore/quotas), checked 26 October 2026.

Source `functions/managed-schools.js` `identity()` reads membership, entitlement and licence status for each licensed administrator request. Storage/read-view caches do not cache these authorization reads. `school-change-feed.js` shares the school subscription across PCs but each incoming long-poll request still authenticates. The table assumes a steady new request every 20 seconds, eight active hours, all schools licensed; actual request cadence is not measured here.

| Scenario | Requests/day | Authorization reads/day | Multiple of free reads |
|---|---:|---:|---:|
| 400 schools × 1 PC | 576,000 | 1,728,000 | 34.56× |
| 400 schools × 5 PCs | 2,880,000 | 8,640,000 | 172.8× |

Formula: schools × PCs × active hours × 3,600 / request interval × 3 reads. Listener initial/delivery/reconnect reads, device checks, retries and all other actions are additional. The scenario is not a measured traffic forecast. Disabling current licence/revocation verification to make this arithmetic fit is not an acceptable repair.

`attendance-queue.js` uses durable create, claim and finish: at least three successful Firestore writes per new completed entry, before hints and other bookkeeping. One daily entry for all 100,000 students therefore requires at least **300,000 writes (15× free allowance)**; entry plus exit requires at least 600,000. Adaptive batching reduces remote calls, not these three per-entry durable state transitions. The current Firebase billing plan and actual billable project usage were not available through the connected tools; no billing change was made.

Reproduce the arithmetic without network activity:

```sh
node .github/scripts/sync3_capacity_budget.cjs
node --test .github/scripts/sync3_capacity_budget.test.cjs
```

## Per-school Google boundaries

Apps Script quotas are per executing user and reset 24 hours after first use. Consumer/Workspace URL Fetch allowances are 20,000/100,000 daily and Properties reads/writes 50,000/500,000 daily. Both have six-minute execution and 30 simultaneous executions/user, plus 1,000/script. Trigger runtime is a separate 90-minute/six-hour daily allowance; it is not a general web-request runtime pool. [Official Apps Script quotas](https://developers.google.com/apps-script/guides/services/quotas), checked 26 October 2026.

Schools deployed as separate school accounts have separate user budgets; projects sharing an executing owner share that user's limits. Neither one Script nor a central developer account acquires 400 independent user budgets by changing School IDs. Script locks and the existing per-school ordered writer further constrain simultaneous mutations.

Native upload includes multiple provider calls per chunk. In the normal no-expiry/no-retry path with N chunks, explicit URL Fetch calls are approximately `3N + 5`: initialization, repeated metadata/status checks, chunk PUTs and final verification. Forty 512 KiB chunks for a 20 MiB file therefore use about 125 calls. A consumer allowance would fund at most 160 such clean uploads before other URL Fetch work; this is arithmetic, not measured upload capacity. Retries, status probes, partial chunks, DriveApp operations and permission/byte fallback can add work. Count school workloads rather than treating an upload as one provider request.

## Drive API quota model changed in 2026

Current official documentation describes **quota units**, not a uniform request count: 1,000,000 units/project/minute and 325,000/user/project/minute. Example costs: item read 5, list 100, download 200, update 50, other actions such as generateIds 5. It also states 1 TB project daily egress and a 400,000,000-unit daily billing threshold, with billing details subject to later notice. Projects using the API November 2025–April 2026 retain prior quotas. [Official Drive limits](https://developers.google.com/workspace/drive/api/guides/limits), checked 26 October 2026.

Actual quota settings for each school Script's Cloud project were not inspected. Do not apply the old 12,000-requests/minute rule to all schools or assume each HTTP chunk consumes identical units. Account storage, Apps Script, Drive backend throttling and central Firestore remain additional boundaries. No billing threshold was exercised or payment configured.

## Observed TEST resources, not a load test

Connected Render resource `srv-db3tgfu7bikc73abm7a0` was confirmed to be the existing `saarthi-sync-v2-test`, Singapore, free plan, one configured instance, auto-deploy off. No service setting was changed. Read-only metric window: **26 October 2026 15:30–16:30 IST** (10:00–11:00 UTC), five-minute resolution.

| Observed metric | Result | Interpretation |
|---|---|---|
| CPU | 12 samples, maximum 0.0068695033 CPU against 0.15 limit | Maximum sampled average ≈4.58% of allocation; short bursts are not represented |
| Memory | 13 samples, maximum 128,266,240 bytes against 536,870,900 | ≈122.32 MiB, 23.89% of reported limit |
| HTTP request-count series | No data | No provider request-rate claim available |
| HTTP latency series/p95 | No data | No provider p50/p95/p99 available |

Two instance labels occur around a deployment; the service configuration is still one instance, not proven two-instance horizontal capacity. A bounded application-log sample from 16:20–16:30 IST contained 100 log lines with `hasMore:true`, including 81 status-200 completion events, expected 401/403/409 checks and two `DEVICE_ROLLOUT_DISABLED` 503 events. This truncated, mixed acceptance sample cannot establish request rate, overall error rate or absence of 502s. Empty HTTP request-log results do not prove zero application errors.

Existing hosted real-cloud evidence (run [40301859618](https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/40301859618), source 7ada97b) measured one queue→ACK at 14,200 ms and Windows→mobile-read at 74,376 ms including injected failures/login. These are specific correctness samples, not representative p95 and not an extrapolation to 400 schools. Separate current latency acceptance should carry exact stage/sample definitions.

## Required throughput and remaining measurement

A 100,000-entry arrival burst requires 27.78 completed entries/second to clear in one hour, or 3.47/second across eight hours. At a full 25-entry batch and one sequential worker, total batch service time must average ≤0.9 seconds or ≤7.2 seconds respectively; with two independent-school workers, ≤1.8 or ≤14.4 seconds per worker. Current adaptive concurrency starts at one and caps at two; slow/error batches reduce concurrency. Actual full-batch service time under representative demand was not measured. One-entry ACK timing cannot substitute for that measurement.

Before any 400-school certification, record representative request mix, schools concurrently active, students logging in/marking entry/exit, PC counts, media sizes, listener churn and background behavior. Obtain read-only actual Firestore/API usage and quota settings, then use a bounded owner-approved provider load schedule with explicit request/byte/write budgets and stop conditions. Measure applied ACK correctness, backlog drain and p50/p95/p99 under that workload. Do not exhaust quotas, add 400 real accounts or enable paid resources merely to obtain a passing report.

Physical Windows 1/2/5-PC and Android hardware, battery restrictions, process termination and real network disruption remain separate unverified gates. Preserve the durable queue and original operation IDs throughout.

## Rollout and rollback precaution

The accepted native-upload fixture is not proof that every pending upload is complete. During a deployment, preserve each original upload key and Script's private `VS_UPLOAD_SESSION_*` journals; offsets are not committed receipts. Do not clear sessions/queues, change school roots or opt out mid-flight to obtain a clean rollout. Drain or resume admitted work through the compatible owner and verify final file/hash before ACK. A rollback to a broker without native capability must not silently replay an uncertain upload through a second writer. The staged rollback review must account for this boundary as well as database and Script compatibility.
