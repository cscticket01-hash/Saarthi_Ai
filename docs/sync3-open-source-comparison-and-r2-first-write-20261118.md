# Sync Engine 3.0 — external Cloudflare/Drive reuse and delivery audit (18 Nov 2026)

This is a code-and-contract comparison, not authorization to replace the existing Sync 3 owners. No third-party source was copied into this branch.

## Existing Saarthi owners (reviewed on main at 0b102160)

- `cloudflare-sync/src/worker.ts`: school-scoped Durable Objects, independently scheduled broker/Google Drive delivery, alarm retry, R2 admission and verified cleanup.
- `cloudflare-sync/src/r2-stage.ts`, `r2-capacity.mjs`: private immutable byte staging, global 8,000,000,000-byte school budget plus 2,000,000,000-byte system reserve, 24-hour *verified-only* retention.
- `cloudflare-sync/src/spool.ts`: original operations, hashes, file parts and durable processing/recovery state.
- `functions/cloudflare-delivery.js`: signed owner path, Drive resumable chunks, exact Google file ID and original operation/metadata verification; provider pressure and retry.
- `school-backend/managed/SaarthiResumableUpload.gs`: server-owned Google sessions, content SHA-256 readback, fixed upload identity and durable acknowledged offsets.
- `lib/cloudflare_record_handoff.dart`, `lib/windows_drive_delivery_queue.dart`: Cloudflare receipt != Google verified; preserve local original until matching Drive proof.

The Windows original outbox and legacy/atomic operations must **not** be replaced with a second generic uploader.

## External projects investigated

| Public reference | Source/license (verified where available) | Useful pattern | Direct copy/paste? |
| --- | --- | --- | --- |
| [aynh/cloudflare-gdrive](https://github.com/aynh/cloudflare-gdrive) | MIT | Cloudflare Worker → Drive OAuth and upload routing | **No**: single configured Drive root and bearer auth, unlike signed per-school Script owner. Adapt only with school-scoped credentials and original revision receipts. |
| [tongGoogle/gdrive-upload-robot](https://github.com/tongGoogle/gdrive-upload-robot) | GPL-3.0 | Worker webhook → Google file upload | **No**: Telegram webhook, service-account destination and GPL obligations do not match managed-school identity. |
| [abilfida/OmniDrive](https://github.com/abilfida/OmniDrive) | MIT | Encrypted OAuth, multi-account scope, replayable change tokens | **No**: an independent Cloudflare D1/KV stack would duplicate tenant and delivery authority. |
| [attacker2007/autobackup](https://github.com/attacker2007/autobackup) | MIT per public README | Rclone-based scheduled R2/Drive backups | **No**: requires a separate long-running service and explicit per-school credential/ownership design. |
| [rclone/rclone](https://github.com/rclone/rclone) | MIT | Resumable/checksummed backup transport | **No**: standalone binary; cannot paste its Go code into Worker/Flutter or use it as a proof of original Script record commit. |
| [fa7ar/o-drive](https://github.com/fa7ar/o-drive) | License not verified in this audit | Multi-provider adapters and transfer-queue design | **No** until license and queue ownership are independently verified. |

Do not port refresh tokens, unscoped folder IDs, service-account keys or public upload endpoints into the school app. Preserve the school's own Apps Script deployment and signed authenticated broker.

## Verified safe improvement in this PR

For a **first-ever** staging receipt, the global R2 quota actor already serializes an immutable reservation and prevents concurrent re-use of its key. Therefore an R2 `HEAD` before the first `PUT` is unnecessary. This PR skips that single request only for a newly inserted reservation. It continues using `HEAD` for prior reserved operations after possible timeouts/crashes, retains byte hash and size checks, and does not issue Cloudflare ACK before R2 confirms persistence. The existing stored/verified/purged replay guards remain unchanged.

Reject malformed `R2_STAGING_SCHOOLS` comma lists with empty tokens, rather than silently accepting the valid subset. The explicit `*` all-school flag and legacy TEST singleton remain unchanged.

New Miniflare runtime coverage exercises fresh PUT without HEAD, immutable replay without re-upload, ambiguous failed PUT with checked retry, exact returned bytes, and quota conservation. Selector tests exercise invalid trailing/leading/double commas.

## Still pending and NOT claimed by this PR

1. PR #320 (original student/teacher photos) and #321 (existing document replacement) need their independent TEST PRs #323/#324, exact Google file/record readback and CI before main activation.
2. Multi-file/atomic person+photo+ID, delete-everywhere, logos/seals and old-version compatibility need verified handoff protocols, not a generic upload shortcut.
3. Main and the actual production Render branch (`windows/easy-connect-draft` in last documented inspection) must be reconciled against the *deployed* Worker version, school Script capabilities and secret bindings; a GitHub merge is not production deployment.
4. Validate app-exit and actual device-shutdown independence after Cloudflare ACK, physical Windows/Android cross-version behavior, measured 2–5-second performance p50/p95 and genuine elapsed 24-hour verified-only cleanup.
5. Production is **not** a safe automatic deploy target for this branch. R2 already has a manually verified active production configuration; preserve `R2_STAGE`, `LANES`, `EDGE_KEY` and the real broker URL. Do not run bare `wrangler deploy`.

## Review commands (after Worker dry-run build)

```bash
cd cloudflare-sync
npm ci
npm run build
node --test test/r2-first-write-fast-path.test.mjs test/r2-scoped-admission.test.mjs
npm test
npm run check
```

Acceptance requires a passing exact-commit CI run, and then a separately authorized, measured staged deployment before any release claim.
