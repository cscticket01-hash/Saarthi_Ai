# Production Cloudflare R2 — live configuration snapshot (17 November 2026)

This file documents **verified live settings**, not a proof that every file has reached Google Drive.

## Actual production Worker settings (read-only verified from connected Cloudflare account)

- Account `62368adf01f421ed7bc5123f3fad66af`, Worker `vidya-saarthi-sync`
- Production R2 binding `R2_STAGE` → private bucket `saarthi-sync-r2-prod`
- `R2_STAGING_ENABLED=true`, `R2_STAGING_ALL_SCHOOLS_ENABLED=true`, `R2_STAGING_SCHOOLS=*`
- `BROKER_URL=https://saarthi-oauth-staging.onrender.com/school-cloud`
- Production Worker at 100% version `fb411835-fd40-45a8-9498-63d35e5a4e58` on 17 November 2026
- The `EDGE_KEY` is a Worker secret; **not** stored in Git, and must remain the existing production value
- No bucket lifecycle auto-delete rule for old objects; only unfinished multipart uploads are aborted after seven days. Verified-only, per-school 24h cleanup remains application logic, not a bucket-wide expiry

## Configuration choices

`wrangler.production-active.jsonc` is a **manual-only** snapshot of the live settings. It preserves the existing production DO `LANES` identity, compatibility, broker URL and R2 bucket. It must **not** be used automatically by normal PR CI or a build. Explicit deployment of this file always requires a review of production runtime code and Render broker compatibility.

`wrangler.production-standby.jsonc` remains a **fail-closed rollback** of R2 admission and should NOT be mistakenly deployed over the verified current Worker, because it would disable R2 admissions.

`wrangler.jsonc` remains default no-R2 config for tests or non-production CLI use. A bare `wrangler deploy` would **not reproduce** the current live production R2 bindings. Production deployments must explicitly choose the reviewed active configuration, not silently replace it with default settings.

## Release verification

1. Keep `R2_STAGE`, `EDGE_KEY`, `LANES` and broker URL intact; never copy TEST secrets, school IDs or R2 buckets.
2. Verify real school Cloudflare ACK is backed by original immutable bytes, respecting the existing 8GB usable / 2GB reserve and R2 verified-only retention.
3. Verify independent Drive upload and exact file/document/record metadata readback for new and old client versions, including app exit, retries and conflicts.
4. Confirm actual production backend branch/deploy matches the source being released. As of the check, Render `saarthi-oauth-staging` deploys from `windows/easy-connect-draft`, **not** GitHub `main`; merging into `main` does not deploy new Render code.
5. Never claim full file sync or 2–5 second device acceptance until measured device tests and actual Google confirmation exist.

Static safety check: `node --test .github/scripts/sync3_production_r2_standby.test.cjs`.
