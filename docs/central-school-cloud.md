# Central school cloud v2 (development only)

One existing developer-managed Firebase project is reused (`platformProjectId` in platform_config.dart). New schools never create Google Cloud/Firebase projects or Firebase web apps. The developer project and runtime credentials are not supplied by school users.

## Authorization and schema

The central HTTPS `schoolCloudApi` verifies Google's access-token audience against the developer's configured OAuth clients, expiry, Drive scope and verified account identity. Server-owned `school_memberships/{uid}` assigns one stable `vs-<32 hex>` schoolId to each initial Google owner. Registration is transactional and retries reuse the same membership. Clients cannot enroll themselves in another school or change membership. School custom tokens carry schoolId/schoolRole and never admin/developer claims.

All operational records live under `schools/{schoolId}/{collection}/{documentId}`. Every record carries schoolId. Firestore rules check live membership, active state and school_admin role, and reject mismatched schoolId, root-level school data, collection-group enumeration, nested path escape, membership edits, secrets and media bytes. Membership revocation applies even to an unexpired Firebase ID token. Existing licensing/developer rules remain available to trusted platform operators; tenant administrators cannot gain those permissions by an admin flag.

Collections cover students, teachers, student/teacher attendance, schedules, notices, calendar, exams/results, payroll, fees, expenses, settings, scanner indexes, document/backup references. Audit logs are append-only. The same schema/API is reusable by future Windows/web clients; no central website UI or new central mobile session flow is shipped here. Browser origins must be explicitly allowlisted.

## Google Drive

New onboarding requests openid/email/drive.file, not cloud-platform or Apps Script permissions. The school owns its OAuth-authorized Drive. The app recovers or creates its school-marked root folder and the server checks folder ownership, capabilities and tenant marker before saving Connected. File uploads are direct private Drive API multipart uploads; no public sharing permission is created. Photos, branding, documents and receipt PDFs use that root. Metadata references stay inside the tenant. Each upload is limited to 20 MB. Token expiry refreshes through the existing server-only OAuth broker. Google refresh tokens and Firebase sessions are stored in Windows secure storage, not plaintext settings or Firestore; no OAuth client secret/service-account key is included in the client.

OAuth revocation, expired/rejected refresh and partial setup stop with a retry/reconnect message. A connected session is saved only after Firebase rules and Drive ownership verification. Retry recovers membership/folder; it does not create another project. File uploads retain old files and create new revisions as separate files, so interrupted uploads can leave an unindexed file. Do not delete source files automatically. Old Drive files created by another OAuth client are not automatically imported by drive.file; existing links remain retained and owned by the school. Native Drive references are private: school users must have Google access to view them.

## Compatibility and migration

Legacy Firebase/Apps Script links, encrypted credentials and local profiles are preserved separately. Legacy connection/sync remains usable. New per-school provisioning entrypoints are disabled in normal builds; the explicit legacy test flag exists only to exercise regressions in CI.

The migration checkbox verifies the saved legacy administrator, reads that school's supported records, includes local pending data only when the local profile is bound to that same legacy project, and authenticates the same Google email. The server verifies the original project's signed administrator token and binds each source project to one destination school. Batches create only missing documents, preserve timestamps, strip secrets/bytes/local file paths and never overwrite existing destination records. Source data/files/accounts are untouched. Repeat migration skips already imported records. Conflicting destination records require operator review, not automatic overwrite. Old Drive-only spreadsheet data, unlisted legacy collections and old license reassignment require operator-assisted compatibility review; no blanket delete/reset or automatic license transfer is performed. Disconnecting central Firebase clears only the new session and restores legacy connections/profile.

## Developer-only staging preparation (not executed)

Production deployment is explicitly forbidden for this work. Existing Render staging remains an OAuth exchange service; it cannot access Firebase with the OAuth client secret. The new central Firebase API/rules have not been deployed by this branch.

Before an actual Windows acceptance test:
1. Prepare an approved non-production backend/rules validation environment in the ONE developer project, with existing production data protected. Do not substitute a school-owned project. The central default-database rule update needs explicit deployment approval; CI emulator tests do not deploy it.
2. Deploy the reviewed `schoolCloudApi` with managed ADC, configured `SAARTHI_GOOGLE_OAUTH_CLIENT_IDS` (existing GitHub public desktop client ID; optional future web client IDs) and `SAARTHI_SCHOOL_WEB_ORIGINS`. Configure the runtime's documented service-account token-signing permission (iam.serviceAccounts.signBlob) and Firestore access. No private key is downloaded into Windows. Cloud Functions may require developer billing; do not enable billing automatically.
3. Enable Google Drive API and configure drive.file consent once in the DEVELOPER OAuth project. Schools do not perform these steps. Review Google's production OAuth verification/testing restrictions before general availability.
4. Update the approved OAuth STAGING service to this reviewed broker version so `/oauth/refresh` and Drive offline tokens work. Keep the current secret server-side; no new secret is needed. No automatic production service deployment is added.
5. Set repository variable `SAARTHI_SCHOOL_CLOUD_URL` to the approved HTTPS API endpoint. Both Windows workflows compile it, alongside the existing public OAuth ID/broker URL. Missing endpoint deliberately disables new sign-in instead of pretending to be Connected. Existing installations and startup remain usable.

No merge, release, production deployment or billing activation is performed by these changes.

## Windows acceptance

Use two separate school Google accounts and two separate local Windows profiles/devices. Connect A, create a student, attendance, fee, expense and branding/file; restart and verify refresh/persistence. Connect B and verify A's records/files never appear. Cancel/deny permission, revoke Drive permission, lose network midway and retry with the same account. Existing-school migration must retain source records and skip destination conflicts. License Skip keeps the red warning; a valid school-bound license clears it. Do not manually reset checkpoints, delete projects or create Firebase resources for school users.
