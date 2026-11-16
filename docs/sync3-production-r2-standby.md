# Saarthi AI Sync 3 — production R2 private standby (NOT a rollout)

Verified through the connected Cloudflare account on **14 November 2026**:

- Cloudflare R2 bucket `saarthi-sync-r2-prod` exists in APAC, Standard storage class.
- Bucket is private: managed `r2.dev` public domain disabled and no custom domains.
- Its current lifecycle has **no deleteObjectsTransition**. The default rule aborts *unfinished multipart uploads* after seven days; this is not a policy to delete verified or unverified objects.
- Existing TEST bucket `saarthi-sync-r2-test` remains separate, with TEST Worker `vidya-saarthi-sync-test` and its own durable lane namespace and secret.
- Existing production Worker `vidya-saarthi-sync` was **not changed, rebound or deployed** by this preparation. Its latest checked deployed version has no R2 binding.

## Explicitly dormant configuration

`cloudflare-sync/wrangler.production-standby.jsonc` is an **alternative** config and is not used by default `wrangler deploy`. It adds only the production bucket binding `R2_STAGE` and sets `R2_STAGING_ENABLED` to the literal **"false"**.

It retains the existing production broker URL verbatim, solely to avoid an accidental route change. **Do not assume that URL is approved for final production**; identify and verify the actual production broker, storage authority, signing key, account and school scope in a separate signed release review. Never copy TEST secrets, TEST namespaces, `LIVE_SYNC_TEST_SCHOOL_ID` or any TEST data into production.

Static guard: `node --test .github/scripts/sync3_production_r2_standby.test.cjs`.
When preparing deployment, create a reviewed copy of this config only after independent release evidence. Do not enable `R2_STAGING_ENABLED=true` as part of a bucket-creation step.

## Mandatory pre-production gates

1. **Original receipt certainty:** authenticated read-only audit counts all original migration markers and publishes redacted reason categories; CAS-remove only exact immutable original completed receipts or independently verified definitive no-write (if supported by the reconciler). The last TEST verification found **16 unsettled original markers** and `previewWouldClear=0`. A newer superseding Google row or notice receipt cannot prove an older operation.
2. **Real clients:** actual physical Windows/Android devices, old/new binary coexistence, hard app exit, offline writes, retry and 2+/5-PC proof. Hosted runners and emulator builds are useful evidence but not physical-device certification. Use `docs/smart-sync-3-device-acceptance.md` and retain artifact SHA, device/OS, captured operation hash, exact school and revision proof, elapsed timestamps.
3. **Retention:** prove a genuine accepted, verified TEST R2 object and its *same original* receipt survive the whole minimum 24-hour elapsed period, without simulated clocks; also verify unverified staging never expires just due to age. A 24-hour clock-controlled test is not elapsed provider evidence. Do not configure R2 bucket object-deletion rules during verification.
4. **Production canary:** after those checks pass, separately review the production Worker/broker/Google signing deployment; preserve the original Durable Object `LANES` namespace and secret, enable a strictly scoped TEST/CANARY school, require exact R2 acceptance → owner Google readback, then separately authorize broader rollout. Keep the rollback flag `SAARTHI_CF_ALL_DATA_ENABLED=false` until admission is fully safe.
5. **Release:** run build, static config, TEST readback and original-proof release gates at exact proposed source SHA, inspect signed artifacts, and get explicit deploy approval. A synthetic green TEST backup alone is not certification.

**No school records, old operation markers, original local outboxes, TEST Worker storage or production Worker traffic were altered to prepare this private bucket.**
