# Sync Engine 4.0 — platform publication gate

A source PR merge is NOT a user-authorized production release. In particular, a
Cloudflare/Google backup feature may have green isolated CI while the actual
Render service still deploys another branch and the production Worker/Apps
Script remain older. Never publish a native client that requires an undeployed
school-owned adapter or broker capability based only on source CI.

The existing GitHub Actions keep their normal code builds and checks, but
their **publication** jobs now require one explicit trigger:

- Windows: push commit with `[windows-release]`, or manually dispatch its
  release workflow after verifying the exact source and signing.
- Android: push commit with `[android-release]`, or manually dispatch the
  release workflow after checking compatibility and signed APK tests.
- Website: push commit with `[developer-release]` for approved web/rules
  publication, or `[hosting-only]` when approved to update Hosting without
  publishing Firestore rules, or manually dispatch after verifying source.

An unmarked main-branch merge does **not** automatically publish any platform.
`[windows-only]` still suppresses Hosting; `[hosting-only]` never triggers
native publication. The existing native build tests, signing, release tag and
artifact verification remain mandatory after authorization.

Important operational constraints:
1. Align and verify the deployed Render broker commit, Cloudflare Worker and
   per-school signed Google Apps Script versions before enabling any new
   Cloudflare-first record/file/delete or record-only financial path.
2. Verify original Google Drive ACK and every affected school adapter, not
   just a Cloudflare staging ticket or 200 response.
3. Confirm real 24-hour verified-only R2 retention and existing tenant
   capacity guards; do not delete pending R2 objects or reset Durable Objects.
4. Never treat an opt-in release marker as proof that CI or live Google
   acceptance passed. Record the approved source SHA, producer service
   revision, signatures, release asset digests and rollback path.
5. Full production source reconciliation and provider acceptance for Sync 4
   are pending; this gate is a preventative improvement, **not** a release
   approval or deployment.
