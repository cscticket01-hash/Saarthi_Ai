# Isolated attendance capacity acceptance

Status: **user approved isolated real recovery and 1,000/5,000/15,000 attendance load on 2026-10-11, 08:41 IST; live capacity admission is pending measured quota headroom and a complete harness**. This approval supersedes the previous approval-pending status. Existing fsync journal measurements use mocked remote delivery and establish no Google provider capacity. No billing or quota increase is part of this approval.

Confirmed TEST scope: school `vs-db8afb01a3be46a983c8284714d06e5d`, endpoint `saarthi-sync-v2-test.onrender.com`, project `saarthi-ai-df12b`, Render workspace `tea-db06ai2d0e5s73a9d1qg` explicitly selected by the user. The coordinator deployed reviewed commit `cd59bd199de983d20e7da962ba2968adc614c689` to this TEST service after finding auto-deploy disabled; Render deployment `dep-db5ft6id0e5s73fapd80` reached LIVE. Production and billing were unchanged.

The implemented Firestore store performs at least three writes per fresh successful event (create, claim, finish) and two transaction reads. Therefore separate 1,000/5,000/15,000 stages require at least 63,000 writes and 42,000 transaction reads, excluding fixture setup, status polling, pending queries, retries and monitoring. Standard Firestore's published free allowance is 20,000 document writes/day ([official quotas](https://firebase.google.com/docs/firestore/quotas)); do not confuse its 50,000 daily read allowance with writes. Actual database edition/tier, daily usage and shared-project headroom remain unverified. The 15,000 stage alone needs at least 45,000 writes, so it cannot be admitted as a same-day Standard free-tier run even with zero earlier usage. No workload has been submitted on the strength of approval alone.

The updated operator harness `staging_attendance_acceptance.mjs` supports 25/100/1,000/5,000/15,000 preauthenticated identities (default1,000), defaults to one HTTP worker and caps at four. It verifies the known TEST school, ready/project/exact runtime identity and fresh scoped observed quota evidence before provider requests. Firestore reads/writes use separate observed headroom and measured amplification; evidence must explicitly retain zero cost and no billing changes. Missing evidence blocks traffic.

Sanitized atomic fsynced reports retain original operation IDs and capture metadata before submission, failure/pending counts, actual observation duration, P50/P95/P99 and one-second operator CPU/RSS samples. At most three original requests are retried immediately while their permits remain valid. After durable status ACKs, one authoritative attendance collection read verifies deterministic row identity, role/person/day, original capture/operation fields and exactly one logical row. Projection hashes cover those selected fields only; they are not full-record hashes. Throughput requires actual verified readback and includes elapsed/drain time. Reports remain `PARTIAL_NOT_RESTART_VERIFIED` with nonzero exit until actual client/worker restart acceptance is performed.

Local guard/metrics/readback regressions: **8/8 PASS**; one subprocess check proves a missing quota snapshot produces a durable sanitized BLOCKED report with zero requests and no token disclosure. A separate credential-free GitHub workflow verifies these tests. These checks do not certify actual provider capacity. Existing monitoring reads quota descriptors and sampled metrics, but does not certify complete daily consumption/headroom or Apps Script/Drive/Sheets account usage. Actual signed fixture provisioning and actual quota evidence remain unavailable; no high-volume workload was executed. Preserve admission rather than asking for the user's load approval again.

Operator inputs: `VS_TEST_STAGE_COUNT`, `VS_TEST_CONCURRENCY`, `VS_TEST_EXPECT_RUNTIME_SHA`, `VS_TEST_MAX_REQUESTS`, `VS_TEST_MAX_STATUS_READS`, `VS_TEST_DEADLINE_MS`, `VS_TEST_QUOTA_EVIDENCE`, `VS_TEST_ATTENDANCE_FIXTURES`, `VS_TEST_REPORT_PATH`, plus existing TEST school confirmation and local admin ID token. Run only with `--run-isolated-test`. Do not put tokens/session permits into reports or GitHub artifacts. Quota snapshots must represent actual observations; the unit-test fixtures are synthetic and cannot be used for live admission.

## Approval and admission gate

Before any live run, obtain explicit approval of the exact TEST school IDs, backend/client/Script commits, maximum submissions, concurrent requests, duration, request/read/write budgets and cost ceiling. Use synthetic people, never original school data. Require verified TEST runtime identity and school ownership. TEST resources can still share developer-project quotas; check existing usage and production headroom before admitting a run. An unavailable quota measurement blocks admission, rather than implying unused capacity.

First proposed stage: 25 synthetic submissions, one provider request in flight, maximum two delivery attempts per operation, and bounded readback. Escalate to 100, then 1,000/5,000/15,000 only with a reviewed per-stage budget. A 15,000 local burst can be drained with bounded batching; it is not approval for 15,000 simultaneous Apps Script executions. Do not delete fixtures or outstanding intents automatically after the run.

Budget admission uses measured amplification from the first approved stage: estimate Firestore writes/reads per admitted event, Script executions per batch including retries, Drive/Sheets readback requests, monitoring requests and background-worker lease writes. Reserve headroom for existing activity and stop before any approved ceiling. If the free-tier headroom is insufficient, reduce/defer the run; never enable billing to finish it.

## Measurements and correctness

| Measurement | Evidence |
| --- | --- |
| Submission latency P50/P95/P99 | Monotonic client start to durable local save; record all failures separately |
| Admission latency P50/P95/P99 | Start to server queue admission; not cloud success |
| Cloud latency P50/P95/P99 | Original submission to verified provider ACK and authoritative readback |
| Throughput | Unique verified events divided by elapsed wall time; include drain time |
| Failures/retries | Sanitized status/category, attempt count, retry deadline; include timeouts and pending events |
| Duplicate prevention | Resubmit the same bounded sample of original operation IDs; one logical attendance row per event |
| Restart integrity | Stop/restart isolated client and worker while intents are pending; compare original IDs, capture times and canonical record hashes |
| School isolation | Foreign-school access rejected without creating or changing records |
| Resource use | Sample client/worker CPU, RSS and queue depth at one-second intervals; report peaks and sampling gaps |
| Quota use | Provider counters before/after, operation amplification, approved ceiling and remaining headroom |

Do not compute success-only percentiles without reporting unfinished/failed operations and observation duration. Keep local-save, server-admission and provider-ACK distributions separate. Record exact source/runtime identities and synthetic fixture namespace in the report, but omit credentials, personal records and private local paths.

Stop admission immediately on 429/quota exhaustion, ownership/provenance failure, unexpected duplicates, integrity failure or budget exhaustion. On repeated 5xx/timeouts or sustained queue growth, stop the stage and preserve every unacknowledged intent. Respect retry deadlines; no aggressive replay or forced ACK. Finish only already admitted bounded recovery work that remains within the approved budget.

## Provider constraints to recheck at approval

Official documentation checked 2026-10-10; these are ceilings, not measured application throughput:

- [Apps Script quotas](https://developers.google.com/apps-script/guides/services/quotas): six minutes per execution, 30 simultaneous executions per user and 1,000 per script. Per-user daily quotas and associated-product quotas also apply and can change. The effective executing account matters for owner-executed web apps.
- [Sheets API limits](https://developers.google.com/workspace/sheets/api/limits): read and write limits each include 300 requests/minute/project and 60 requests/minute/user/project. These REST API quotas do not substitute for measuring SpreadsheetApp behavior and Apps Script locking.
- [Firestore usage and limits](https://firebase.google.com/docs/firestore/quotas): inspect the actual database tier and project usage before budgeting. Count worker, deduplication, monitoring and readback operations, not only initial attendance writes.

The approval report must contain actual account/project quotas and available headroom. A passing local journal benchmark or emulator result cannot satisfy this gate.
