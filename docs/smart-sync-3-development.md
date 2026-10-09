# Smart Sync 3.0 development evidence

Starting main: `de547d2c0a025db815ce97479e3f4f3fc4f8f1a8`.
Branch: `feature/smart-sync-3`. Production publication is not authorized by this development request.

## Implemented initial stage

- Reuses the reviewed Engine 2.0 cache preservation and automatic recovery fixes from PR #22, without merging that PR or main.
- Deterministic classification of API outages, timeout, network path failure, quotas, access denial, school storage configuration and revision conflicts.
- Windows does not immediately repeat unknown, configuration, authorization or conflict failures. Recoverable outages keep bounded jitter recovery and existing passive reconciliation.
- Structural record failures retain their operation identity and payload, require attention, and allow unrelated records to continue. No local record is deleted by repair.
- Full Windows Sync & Backup Control Center route from Settings: actual pending count, attention count, retained verified receipts, last cloud ACK, complete-sync time, next retry, queue, conflict review, sanitized diagnostics, durable school-specific recovery history, local integrity check, local backup and persisted school-specific automatic-sync preference.
- Internet connectivity is explicitly unverified until independently measured. Receipt count is not misrepresented as unique cloud record count.
- Reuses existing local-first save, version-checked ACK, mobile session renewal and isolated real-cloud tests.

## Existing failure evidence

Render production request `7a8e0438-cc6c-443b-947b-14f7eb68f86f` at `2026-10-09T14:59:01.439Z`: `MANAGED`, `managed/records`, HTTP 502, `SCRIPT_OPERATION_FAILED`.
Owner diagnostic previously returned `No recent sync diagnostic captured`. Underlying Apps Script category/source line remains unconfirmed. No speculative production storage repair is applied.

Production Render remains `f81385dd6dc927f11b18f4a123966a66dfaf2d1b`.
Isolated TEST Render remains `33320babb0e026a9c9e5e65c9434015945e61bb8`.
Original school and its three pending entries are not accessed or changed.

## Isolated component measurement

The local fsync-backed attendance queue benchmark accepted and drained 1,000, 5,000 and 15,000 synthetic submissions with zero failed/lost rows and 1,000 repeated attempts deduplicated in each run. Measured elapsed times were 42.9 ms, 139.5 ms and 279.3 ms respectively. This uses mocked remote delivery, not Google/Firebase capacity or end-to-end attendance latency. The hosted workflow also retains the 10,000/25,000/50,000 component cases and adds 15,000 explicitly.

## Not yet implemented or verified as Engine 3.0

This is an initial development stage, not the completed unified upgrade.

- Independent OS connectivity monitoring and physical reconnect/sleep/resume verification.
- Hourly checkpoint scheduling and resume-triggered retry are implemented. Physical sleep/resume and a full elapsed-hour integration cycle remain unverified; opt-in scheduled Windows worker is not implemented.
- Automatic local/cloud missing-record restoration using verified inventories and authoritative tombstones.
- New 24-hour recycle protocol, cloud snapshots, authorized restore and server-side retention sweep.
- Complete control center service health/storage usage/category counts and guided restore controls.
- New photo/document quality pipeline, original backup policy and recovery verification.
- Central monitoring integration and full client compatibility matrix.
- Live 1,000/5,000/15,000 attendance capacity measurements. Existing fsync queue benchmark is synthetic and its remote ACKs are mocked.
- Original-school repaired sync and durable ACK of the original pending records.

Production readiness: **BLOCKED**. New branch CI and TEST evidence must be evaluated for this exact branch SHA; earlier Engine 2.0 results do not certify this stage.

## Resumed development inventory (2026-10-09)

Recovered HEAD: `76c1291bd0fb0299a0c0710a62e513af77543f92`, existing PR #23. No later Engine 3.0 branch/commit/review/comment found. All five platform/security jobs passed there. Its isolated cloud job was skipped; real cloud evidence belongs to earlier `cdb2901d688ec5823de0a633d360526c9332b0be` test-sequence run. Invisible uncommitted work from another session cannot be recovered.

| Requirement | Actual recovery status |
| --- | --- |
| A control center | Partial: existing page preserved; guided restore remains open; authenticated school cloud-health control added, UI regression pending. |
| B self-repair | Existing bounded recovery hosted-tested; original incident still blocked. |
| C hourly sync | Implemented; physical sleep/wake and elapsed-hour verification pending. |
| D bidirectional recovery | Local missing-cache inventory recovery added to existing manual/hourly managed pull; new SQLite tests pending. Cloud-row authoritative restoration incomplete. |
| E recycle bin | Partial: default-off signed snapshot/restore/retained-audit protocol implemented; local UI, scheduling and actual TEST deployment remain pending. |
| F cross-platform | Prior isolated evidence preserved; no new cloud success claimed. |
| G attendance | Existing durable queue/dedup tested; 15,000-case result is a component benchmark, not cloud throughput. |
| H compression | Existing processor extended with portrait 30 KB and scan 50 KB best-effort targets. Portraits skip paper crop/deskew; originals retained; tests pending. |
| I disaster recovery/monitoring | Existing atomic storage, integrity and backup preserved; guided verified restore and central sync monitoring incomplete. |

Missing-cache recovery excludes explicit tombstones, all pending edits/deletes and deliberately skipped configuration. Original-school records and production resources were not touched. New test/build verification is required before rollout.

### Recycle protocol development, not deployment

`VS_RECYCLE_VERSION=1` is an explicit owner configuration gate; default is zero. Versioned deletion captures and readback-verifies a content-hashed school snapshot before writing a tombstone. Document binaries stay intact during the 24-hour restore window. Signed school-admin restore requires the exact deletion revision, retains original timestamps, refuses newer edits and supports lost-ACK retries. Expired restores and early purges fail closed. Financial audit snapshots are never purged by this mechanism; tombstones and snapshots are retained. Eligible binary cleanup reuses existing immutable-upload ownership/shared-file protections. No live school flag or Script deployment was changed. Local hide/recover UI and scheduled purge are not yet complete; this is not a release-ready recycle bin.

CI found the old default-target test still asserted 80 KB after the requirement changed to 50 KB (106 passed / 1 failed). Its expectation was updated to the specified target; original-preservation and readability checks remain unchanged.

Cloud health is checked only on administrator request through the existing authenticated school session; failed/foreign responses remain unverified and do not gate local UI. This does not claim independent OS internet connectivity or full Drive inventory completeness.

Smart Sync 3.0 review Windows/Android/Web artifacts default to the isolated TEST endpoint, matching the existing TEST build identity guard. Main/production endpoint defaults remain unchanged. Explicit workflow-dispatch endpoint inputs retain the existing reviewed mechanism. This prevents a default Smart Sync 3.0 TEST artifact from synchronizing a saved original-school account; local UI/data remain governed by existing local-first startup. Native file-dialog interaction and physical sleep/wake still require separate device verification.

### Confirmed TEST harness 409 at the IST date boundary

Run `37973826645` passed storage, isolation, real revision/idempotency 409 protection, notice and PDF readback, then failed synthetic attendance acceptance with `ATTENDANCE_CAPTURE_REVIEW`. Its fixed October-9 fixture reused an already completed capture with an October-10 IST permit. The server correctly rejected the mismatched capture day; no production attendance validation was weakened. TEST identities now derive from hosted run ID + attempt, remain stable within that attempt, and are fresh across runs. A capture-authorizing permit is refreshed immediately before the new synthetic capture. Existing timestamps and old synthetic records remain untouched. The production-class cloud test discovers the matching current-run PDF fixture. Regression tests cover stable retries, fresh run/attempt identity and invalid hosted context.

Portrait uploads include both original and optimized content hashes in the immutable upload identity. Different originals that compress to identical pixels therefore cannot reuse a cloud file/cache key and overwrite one retained original. Repeating the same original remains idempotent. Logo/seal/signature upload identities retain their existing behavior. A regression uses two valid PNG originals with different metadata and identical processed bytes, then verifies distinct originals and stable retry keys.

The hosted production-class TEST-cloud harness now additionally exercises actual portrait processing/upload, duplicate cloud-file retry, exact private Drive image readback, aspect ratio, 30 KB representative target and retained original bytes after local SQLite reopen. These are synthetic-image storage checks, not human portrait-quality or physical-device acceptance.
