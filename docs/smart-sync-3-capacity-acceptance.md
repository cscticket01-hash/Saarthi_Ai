# Isolated attendance capacity acceptance

Status: **plan only; live high-volume testing is not authorized**. Existing fsync journal measurements use mocked remote delivery and establish no Google provider capacity. No billing or quota increase is part of this plan.

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
