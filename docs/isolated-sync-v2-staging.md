# Isolated Sync Engine 2.0 TEST service

Service: `saarthi-sync-v2-test`, `srv-db3tgfu7bikc73abm7a0`, free Singapore plan,
draft branch, auto-deploy OFF. Existing `saarthi-oauth-staging` is unchanged.
Creation is not readiness: missing credentials or TEST identity deliberately
prevent startup. No real school identity may be configured.

## Owner configuration (no secrets in chat)

1. In the existing developer website, using the authorized developer login,
   create a NEW synthetic school named `TEST Sync V2`, with a separate unused
   login email/password. Leave existing-Google-account linking OFF. Record the
   generated `vs-` School ID; never reuse a real school's ID or storage binding.
2. Open the new service's Render Environment page. Through that secure account
   UI, configure server-only `SAARTHI_FIREBASE_ADMIN_JSON` for the existing central
   project, and `SAARTHI_GOOGLE_DESKTOP_CLIENT_ID` (plus Desktop client secret only
   if that client requires it). Do not change the original service or billing.
   Set `SAARTHI_ISOLATED_TEST_SCHOOL_ID` to the NEW TEST ID. The service also checks
   that its verified central school name begins with `TEST` before serving or
   processing attendance. `SAARTHI_ISOLATED_TEST_MODE=true` must remain enabled.
3. Use a distinct 64-hex `SAARTHI_MANAGED_STORAGE_KEY` in this service. Never copy
   production encrypted bindings or queue data. After the scoped backend is
   deployed and the TEST profile verifies, enable its attendance worker by
   setting `SAARTHI_ATTENDANCE_QUEUE_ENABLED=true` ONLY on this new service.
4. If Firestore reports a required composite index, create it ONLY for the
   `attendance_test_outbox` collection: `schoolId` ascending, `nextAttemptAt`
   ascending, collection scope. No paid billing or production queue changes.
5. Configure exact authorized TEST website origins in
   `SAARTHI_SCHOOL_WEB_ORIGINS`; do not use a wildcard or weaken authentication.

The same engine is reused with a separate TEST queue store. Both final ACK read
paths use that store. The existing production worker reads `attendance_outbox`,
so it cannot claim the new `attendance_test_outbox` rows. The TEST worker also
filters by its configured school and refuses foreign create/claim/finish.
Broad developer account management, legacy onboarding and other-school requests
are blocked on this service. Existing membership/licence/session checks remain.

## Dedicated TEST applications

Run `Platform review builds` manually on `windows/easy-connect-draft` after
service readiness. Set `test_school_cloud_url` to
`https://saarthi-sync-v2-test.onrender.com/school-cloud` and
`test_oauth_broker_url` to `https://saarthi-sync-v2-test.onrender.com/oauth/token`.
Inputs affect only that run; shared repository endpoint defaults stay unchanged.
Use the resulting exact-SHA Windows, Android `.syncreview` and Web artifacts.
Do not overwrite the installed real app or its database; use an isolated Windows
user/VM and Android TEST profile. Hosting or production releases are not implied.

## TEST Drive and Apps Script

The preparation folder `13tAOGMSGRopUdK1YSvAy6gEiQeuNMPO1` is not automatically
a school-verified root. In a separate owner-authorized TEST Apps Script project,
use the reviewed combined managed script and manifest. Follow
`manual-school-drive-setup.md`: exact TEST ID, new-storage creation enabled only
for initial preparation, then disabled; deploy that TEST project only. Connect
its `/exec` URL through existing TEST Windows Advanced Settings. No connection
secret needs to be sent in chat. Preserve the actual generated school-marked root.

Seed only synthetic records/files, then follow `organized-school-sheets-plan.md`
for backup, dry run, begin, bounded steps, interruption/resume, concurrent edits,
count/content/link validation and rollback. Do not manually create replacement
Sheets or copy real-school data into a fixture.

## Evidence and acceptance

Record client versions, backend SHA, School ID, operation ID, original scan time,
cloud acceptance and final ACK separately. Measure local save, queue dispatch,
final cloud ACK and Android/Web visibility, before/after pending counts and
duplicate/lost records. Test offline restart, network recovery, minimized Windows,
supported Android background execution and stale-revision conflicts. Do not
promise upload from a terminated app or an exact Android background interval.
No real-device or live migration PASS is recorded by this document.
