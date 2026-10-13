# Self-Healing 2.1 knowledge implementation

Starting main: `15f3049`. Existing PR #30 is merged. Reviewed follow-up PRs #31–43 include real diagnostic progress, lifecycle isolation and owner timer repairs. Open #44 (visible conflict verification) is not silently merged into this branch.

## Actual scope

**Exactly 1,000 diagnostic cases: 4 A, 462 B, 534 C.** The 26 existing provider patterns remain intact; 974 additional cases are real constant throw operands scoped to their source file and exception kind. Same text in separate owners is explicitly a different contextual guard, not a newly discovered root cause. No invented cross product, placeholder, generated exception or production incident is counted. The source inventory spans 118 files and 15 source-owner domains plus the existing infrastructure/inventory providers. This is a knowledge-library target, **not 1,000 executable fixes or 1,000 continuously observed providers**. Notices have no constant throw guard in this inventory and no new notice failure observation is claimed. No DNS/SSL/root-provider cause is inferred from a generic timeout.

`tool/extend_health_knowledge.py` lexes comments/strings atomically and collects only complete, non-interpolated constant throw operands. Stable round-robin selection across actual files prevents a large owner from excluding managed Script, finance, backup or late Windows sources. `sourceCase` stores a reviewed source path, line, kind and constant literal; its ID hashes path/kind/literal. Validation re-derives the inventory from the current source and fails on removed/moved guards, changed types, forged IDs or solution/permission drift. The catalog must contain exactly 1,000 entries. Regenerate and review source changes before compiling; never edit generated Dart directly.

Existing `HealthRuntime` wrappers consult the exact, component-scoped kind/literal index. Only an unambiguous constant source error becomes a local catalog ID. An explicit read-only `matchSourceCase` interface supports known owner context; broader backend/legacy/platform cases are searchable guidance until an owner supplies that exact context. Arbitrary exception text, interpolated messages, mismatched components and ambiguous messages do not receive a source diagnosis. No raw caller text is retained or exported. These APIs cannot register a callback or invoke recovery. Legacy guards are knowledge about existing legacy branches, not instructions to provision new per-school cloud resources.

A = existing reviewed infrastructure capability, conditionally eligible. B = owner/manual guidance; no guardian business executor. C = detect/escalate only. Existing Windows runtime has four provider registrations and three unique action IDs (shared `restore-owner-timer` has two owners). This change adds **zero new executable playbooks**. Safe capabilities already added in merged #40 are reused.

## Architecture and authority

`catalog.v1.json` is versioned declarative data with all required evidence, solution, risk, admission and verification fields. `build_health_knowledge.py --check` validates schema, distinct signatures, source/test references, bounded permissions and generated-source parity. `catalog_data.dart` is a compiled local snapshot, lazily decoded once. Matching uses indexed exact component/failure/typed-category and source-context ID keys; nested rule data is immutable; unknown signals remain unrecognized. Search is capped at 32 results and 120 characters. No catalog rule can register a callback or grant authority.

The existing provider v2 contract / `RecoveryLease` / `ownerTimerProvider` remain the coordination contract. `sync-scheduler` observes owner expected/running state and calls public `repairAutomaticSchedule` only for the missing enabled reconciliation timer. Smart Sync independently rechecks school/profile, paused/in-flight state and timer state. No guardian calls to `syncNow`, queue writers, record retry admission, conflict commit, ACK or reconciliation checkpoint writers were added. Existing Sync owns all business recovery. A scheduler timer is not sync evidence.

Attributed audit events add optional playbook ID/provider contract version, preserving legacy schema-2 reads. Bounded school/profile history pairs admitted starts with at most one verified/unverified/timeout terminal. Only current-provider-version, matching-failure outcomes rank registered alternatives. Even unfiltered report learning cannot pair a terminal with an admission from a different failure/provider version. Unattributed legacy history cannot influence selection. Ranking cannot introduce actions or relax conservative component attempt/cooldown/circuit budgets. Reports label retained-window statistics; no lifetime success-rate claim.

Transparent hypothesis ranking assigns two evidence points to the owner's transport category and one each to concurrent database failure and measured >=45s end-to-end latency. These are heuristic evidence points, not probability or a confirmed root cause. Existing latency-trend warning stays uncalibrated. No external AI service is invoked.

Windows monitor adds a searchable Error Knowledge dialog. Existing Run Diagnostics, pause/resume, diagnosis, history and sanitized export are retained. Knowledge ID, solution, verification, hypotheses and attributed history appear in existing reports. Export Sanitized Diagnostics opens a JSON preview and Copy report writes that sanitized snapshot to the clipboard; school/profile names, operations and unapproved metrics are excluded. Android remains a hidden observer.

## Known incident limitations

The generic 45-second TimeoutException and retained-pending server message do not establish a failing stage. Exact original-school slow-stage tracing, owner Apps Script logs and physical-PC pending operations were not available in this change. Confirmed client defect fixed: CentralSchoolCloud.send bounded only response headers; body collection could wait indefinitely. The same 45s deadline now bounds headers plus body together and exposes a fixed sanitized headers/body timeout stage. Synthetic tests delay headers 44s then stall the body, stall headers entirely, and deliver a late success; no duplicate retry, shared-client close or retrospective success occurs. This does not establish the original-school backend root cause. The typed headers/body stage now survives `windowsSyncRecovery`, `SyncRecoveryDecision`, the Windows adapter and sanitized local diagnostics. Generic/HTTP 504 deadlines remain stage Unknown, rather than inventing upstream evidence. Retry classification and delays are unchanged. A Future deadline does not cancel a possible server commit or the underlying transport; retries remain exclusively owner-managed. No deadline increase or production restart/deploy was attempted. Diagnostics-button and lifecycle defects were already fixed on main; this branch preserves them.

## Validation

Python catalog fault tests and generated parity run locally. Flutter strict analysis, all-pattern matching/false-positive tests, ranked uncertainty, legacy audit parsing, bounded history learning, A/B isolation, existing guardian and Sync/QR/ID/attendance owner regressions, 100,000-observation benchmark, Windows/Android/Web builds run in Draft PR CI. See PR and completion report for exact final counts/status, rather than interpreting workflow configuration as a pass.

Performance benchmark compares a linear reference lookup to indexed matching on the **actual 1,000-case catalog**, with 100,000 synthetic signals, cold load and process RSS delta. The benchmark cycles across every case, requires 1,000 distinct matched IDs and checks indexed/reference parity for 100,000 observations. It measures cold load and process RSS as well. This remains synthetic Dart process evidence, not real Windows UI latency, low-end PC CPU budget or a 24-hour app soak.

## Release blockers

This remains a Draft: broader continuous owner observations are not established for every source case; no new reviewed business-recovery capability exists; original-school slow-sync root cause is unconfirmed; final physical Windows/Android, representative resource/load, full continuous 24h soak, five-PC/device topology and live exact-source cloud acceptance remain separate gates. No main merge, production deployment, EXE/APK publication, paid service or school-data mutation is authorized here.

## Original provider-pattern reference (26 of 1,000)

The full 1,000-case searchable reference is `lib/health/knowledge/catalog.v1.json` and the Windows Error Knowledge dialog. Supplemental entries include exact source/line, guard kind, safe owner guidance and verification; none can execute a repair.

## Searchable reference

| ID | Component | Level | Symptom | Solution |
|---|---|---|---|---|
| sh-smart-sync-networkpath | smart-sync | B | School server network path unavailable | Allow the existing Sync owner to retain and retry the same operation under its network backoff. Check connectivity without reauthentication. |
| sh-smart-sync-timeout | smart-sync | B | School response deadline exceeded | Retain pending operation IDs. Correlate measured client/broker/Script stages; the existing Sync owner alone admits a bounded retry. Do not increase the deadline without locating the slow stage. |
| sh-smart-sync-server | smart-sync | B | School server rejected or failed a request | Retain the queue; owner classifies server status and schedules eligible retry. Correlate sanitized broker and upstream evidence; no production restart or deploy. |
| sh-smart-sync-quota | smart-sync | B | School provider rate limit | Wait for owner quota deadline. Do not bypass Retry-After/backoff or launch duplicate work. |
| sh-smart-sync-authorization | smart-sync | C | School authorization rejected | Verify the current school account and permissions with the operator. Never refresh privileges or bypass licence/authentication automatically. |
| sh-smart-sync-configuration | smart-sync | B | School storage configuration rejected | Inspect protocol, bundle version and owner storage diagnostics. Keep the existing root and secret; prepare a reviewed configuration fix. |
| sh-smart-sync-conflict | smart-sync | B | Different local and cloud revisions | Use authenticated owner Conflict Review to compare both versions. The guardian must not choose a winner or overwrite newer data. |
| sh-smart-sync-validation | smart-sync | B | Pending record input rejected | Use owner record review to correct required fields; retain originals and operation identity. Never replace a cloud school profile with blank fields. |
| sh-smart-sync-filemissing | smart-sync | B | Original pending media unavailable | Restore operator access to the original file, then let its owner verify hash and retry. Never substitute an empty or generated replacement. |
| sh-smart-sync-unknown | smart-sync | C | Unclassified sync failure | Collect the typed owner request reference and stages. Leave Needs Attention; no automatic retry invented from the exception message. |
| sh-sync-view-worker | sync-view | A | Missing derived sync display projection | Refresh only the owner-derived local display while Sync is not busy. Do not edit queue or receipt rows. |
| sh-monitor-worker-worker | monitor-worker | A | Guardian heartbeat missing | Re-arm the guardian diagnostic timer using a valid lease while monitoring is enabled. No business callback is invoked. |
| sh-sync-scheduler-worker | sync-scheduler | A | Owner reconciliation timer stopped | Ask the owner to restore only its missing reconciliation timer. Preserve anchored checkpoints, retry dispatch and paused state. |
| sh-health-report-timer-worker | health-report-timer | A | Sanitized reporting timer stopped | Ask the reporter owner to restore its missing enabled timer; preserve any pending report and in-flight transport. |
| sh-database-storage | database | C | Local storage owner reports access failure | Retain the database. Verify disk access/free space and original availability; request storage-owner diagnostics. No reset, deletion, queue clear or speculative corruption repair. |
| sh-documents-timeout | documents | B | Processing deadline exceeded | Keep the original and in-flight work. Locate the processing or owner request stage; wait for actual settlement and let the owner authorize any retry. |
| sh-documents-decoding | documents | B | Input/response cannot be decoded | Keep the original bytes. Check supported format and owner parsing contract; review input/response with its owner, without uploading a broken replacement. |
| sh-documents-unknown | documents | C | Unclassified processing failure | Retain originals. Obtain sanitized owner stage evidence; no automatic worker restart or business retry is available. |
| sh-id-card-timeout | id-card | B | Processing deadline exceeded | Keep the original and in-flight work. Locate the processing or owner request stage; wait for actual settlement and let the owner authorize any retry. |
| sh-id-card-decoding | id-card | B | Input/response cannot be decoded | Keep the original bytes. Check supported format and owner parsing contract; review input/response with its owner, without uploading a broken replacement. |
| sh-id-card-unknown | id-card | C | Unclassified processing failure | Retain originals. Obtain sanitized owner stage evidence; no automatic worker restart or business retry is available. |
| sh-inventory-timeout | inventory | B | Processing deadline exceeded | Keep the original and in-flight work. Locate the processing or owner request stage; wait for actual settlement and let the owner authorize any retry. |
| sh-inventory-decoding | inventory | B | Input/response cannot be decoded | Keep the original bytes. Check supported format and owner parsing contract; review input/response with its owner, without uploading a broken replacement. |
| sh-inventory-unknown | inventory | C | Unclassified processing failure | Retain originals. Obtain sanitized owner stage evidence; no automatic worker restart or business retry is available. |
| sh-qr-decoding | qr | B | School QR link parse rejected | Use the QR owner to verify the supported link format. Retain the original credential; do not regenerate or reissue it. |
| sh-qr-unknown | qr | C | Unclassified QR owner failure | Collect QR owner diagnostic evidence without storing credential contents; leave Needs Attention. |
