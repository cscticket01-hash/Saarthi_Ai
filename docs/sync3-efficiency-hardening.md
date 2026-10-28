# Sync Engine 3 efficiency and recovery hardening

Date: 28 October 2026. Local implementation; no production deployment.

## Implemented

- Windows retry admission takes the later of its existing deadline and the new provider minimum. An active shared quota wait cannot be overwritten by an earlier row retry. Manual Sync Now also respects that provider wait.
- The Windows profile persists bounded, same-school quota evidence locally. Restart recovery ignores expired, foreign-school, future-observation and over-one-day evidence. A failed local metadata write leaves in-memory admission closed.
- Cloudflare diagnostics show a first-request failure and malformed/incomplete status instead of silently disappearing. Only verified completed/healthy status clears the message. No queue/history entry is removed to clear UI text.
- Attendance school turns rotate in the bounded fetched window. Per-school order and the existing maximum of two independent-school workers remain intact.
- A quota failure stops that school's remaining claims; another school can continue. The broker's existing owner cooldown is checked before claims, including freshly constructed edge delivery queues and configured schools sharing an owner.
- Attendance worker wake signals cannot advance a shared provider quota deadline.
- Cloudflare pressure uses the configured Worker endpoint as its shared local scope. Trusted, server-configured Google owner fingerprints can group schools sharing an executing owner. Request payloads cannot choose these scopes.
- An optional shared Google/Cloudflare pressure journal persists hashed scope metadata in Firestore. One listener per broker supplies a local view; healthy calls add no journal transaction per request. Expired known gates use transactional probe leases, and a stale success cannot clear a newer failure. Failed subscriptions retry after 30 seconds. Journal operations have bounded response budgets; cleanup failure cannot discard a verified provider ACK.

## Activation and limits

Shared journal mode remains OFF unless `SAARTHI_SHARED_QUOTA_ENABLED=true`. It writes only `sync_provider_pressure/<project-hash>` coordination metadata and has nonzero Firestore read/write/listener cost. Validate that budget and permissions before enabling. Google owner grouping is supplied by `SAARTHI_GOOGLE_QUOTA_SCOPES`: a JSON mapping from valid school IDs to operator-verified 64-character lowercase SHA-256 owner fingerprints. Never infer shared execution ownership from a user-entered school ID or login email. Without mapping, Google uses school scope.

The journal's normal admission view follows Firestore listener delivery, so it is not an instantaneous global request-rate limiter. Recovery of a known expired gate is transactionally claimed. If a quota event cannot be persisted, local cooldown still applies but cross-instance persistence of that event is not guaranteed. Firebase's own admission gate remains local to avoid depending on exhausted Firebase to authorize its own recovery; durable client/server row deadlines remain the existing recovery boundary.

School fairness is bounded to fetched rows; it does not certify fairness to schools outside that query window. This change introduces no larger query window or extra queue scan solely for fairness. Actual remaining quota, provider daily reset time and account-wide usage are not invented. No speed multiplier, free-plan capacity or zero-failure guarantee is claimed.

Existing delta reads, adaptive independent-write batching, operation IDs, revision checks, receipt validation, per-record dependency order and record-before-media stages are retained. No new parallel writer or alternate record authority was introduced. Existing Google Script code was not changed because this work concerns owner admission and scheduling.

## Verification

- Full backend regression suite: 635 passed, zero failed.
- Targeted pressure/journal/attendance suite: 40 passed (included in the full suite).
- Dependency-free Dart policy checks passed for retry minimums, restart/school isolation, quota delays, conflict protection and status recovery.
- Edited Dart files parse with the installed Dart formatter; `git diff --check` passes.
- Shared-state tests simulate restart, two broker instances, probe crash, stale ACK, journal corruption and subscription failure. They do not establish live Firestore/Cloudflare behavior or billable usage.
- Full Flutter analysis, widget tests and physical Windows/Android acceptance remain pending. Earlier Flutter dependency setup was blocked by automatic approval review after an unexpected instance-metadata request; that setup was not retried or run indirectly.
- No public push, PR, merge, app release, provider deployment, billing change or private school data mutation was performed in this hardening turn.

## Rollout and rollback

Review the local branch, run full Flutter and actual device acceptance in an explicitly approved environment, then deploy the compatible broker and clients. Enable shared journal mode only after its initial snapshot and isolated-school recovery checks succeed and owner grouping is verified. Use unchanged operation IDs and queue journals during rollout.

For an optional-journal issue, disable the flag to restore local-only broker admission while retaining queued work. For code rollback, deploy the prior compatible broker/client revision without deleting queues, receipts or school roots. Existing persisted retry deadlines should be allowed to expire; do not erase pending work to make the UI look healthy.
