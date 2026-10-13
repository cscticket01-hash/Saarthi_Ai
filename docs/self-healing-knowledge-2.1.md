# Self-Healing 2.1 knowledge implementation

Starting main: `15f3049`. Existing PR #30 is merged. Reviewed follow-up PRs #31–43 include real diagnostic progress, lifecycle isolation and owner timer repairs. Open #44 (visible conflict verification) is not silently merged into this branch.

## Actual scope

26 source-backed typed patterns, not 1,000 fixes: **4 A**, **15 B**, **7 C**. Remaining target coverage: **974 NOT IMPLEMENTED**. Source-backed means reachable behavior and synthetic matching evidence, not a production incident or proof that a live school was repaired. The 16-domain target is not complete. No DNS/SSL/root-provider cause is inferred from a generic timeout.

A = existing reviewed infrastructure capability, conditionally eligible. B = owner/manual guidance; no guardian business executor. C = detect/escalate only. Existing Windows runtime has four provider registrations and three unique action IDs (shared `restore-owner-timer` has two owners). This change adds **zero new executable playbooks**. Safe capabilities already added in merged #40 are reused.

## Architecture and authority

`catalog.v1.json` is versioned declarative data with all required evidence, solution, risk, admission and verification fields. `build_health_knowledge.py --check` validates schema, distinct signatures, source/test references, bounded permissions and generated-source parity. `catalog_data.dart` is a compiled local snapshot, lazily decoded once. Matching uses an indexed exact component/failure/typed-category key; unknown signals remain unrecognized. Search is capped at 32 results and 120 characters. No catalog rule can register a callback or grant authority.

The existing provider v2 contract / `RecoveryLease` / `ownerTimerProvider` remain the coordination contract. `sync-scheduler` observes owner expected/running state and calls public `repairAutomaticSchedule` only for the missing enabled reconciliation timer. Smart Sync independently rechecks school/profile, paused/in-flight state and timer state. No guardian calls to `syncNow`, queue writers, record retry admission, conflict commit, ACK or reconciliation checkpoint writers were added. Existing Sync owns all business recovery. A scheduler timer is not sync evidence.

Attributed audit events add optional playbook ID/provider contract version, preserving legacy schema-2 reads. Bounded school/profile history pairs admitted starts with at most one verified/unverified/timeout terminal. Only current-provider-version, matching-failure outcomes rank registered alternatives. Unattributed legacy history cannot influence selection. Ranking cannot introduce actions or relax conservative component attempt/cooldown/circuit budgets. Reports label retained-window statistics; no lifetime success-rate claim.

Transparent hypothesis ranking assigns two evidence points to the owner's transport category and one each to concurrent database failure and measured >=45s end-to-end latency. These are heuristic evidence points, not probability or a confirmed root cause. Existing latency-trend warning stays uncalibrated. No external AI service is invoked.

Windows monitor adds a searchable Error Knowledge dialog. Existing Run Diagnostics, pause/resume, diagnosis, history and sanitized export are retained. Knowledge ID, solution, verification, hypotheses and attributed history appear in existing reports. Export Sanitized Diagnostics opens a JSON preview and Copy report writes that sanitized snapshot to the clipboard; school/profile names, operations and unapproved metrics are excluded. Android remains a hidden observer.

## Known incident limitations

The generic 45-second TimeoutException and retained-pending server message do not establish a failing stage. Exact original-school slow-stage tracing, owner Apps Script logs and physical-PC pending operations were not available in this change. No timeout was simply increased and no production restart/deploy was attempted. Diagnostics-button and lifecycle defects were already fixed on main; this branch preserves them.

## Validation

Python catalog fault tests and generated parity run locally. Flutter strict analysis, all-pattern matching/false-positive tests, ranked uncertainty, legacy audit parsing, bounded history learning, A/B isolation, existing guardian and Sync/QR/ID/attendance owner regressions, 100,000-observation benchmark, Windows/Android/Web builds run in Draft PR CI. See PR and completion report for exact final counts/status, rather than interpreting workflow configuration as a pass.

Performance benchmark compares a linear reference lookup to indexed matching on the **actual 26-rule catalog**, with 100,000 synthetic signals, cold load and process RSS delta. This is not a 1,000-rule benchmark, real Windows UI latency, low-end PC CPU budget or a 24-hour app soak.

## Release blockers

This remains a Draft: 974 catalog entries and broader domain observations are missing; no new reviewed business-recovery capability exists; original-school slow-sync root cause is unconfirmed; final physical Windows/Android, representative resource/load, full continuous 24h soak, five-PC/device topology and live exact-source cloud acceptance remain separate gates. No main merge, production deployment, EXE/APK publication, paid service or school-data mutation is authorized here.

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
