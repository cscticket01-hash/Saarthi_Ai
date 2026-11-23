# Windows Admin Security — separated App Lock and school-wide Admin Password (draft)

Status: **implementation branch only; not released or tested**. This change is deliberately isolated from the main branch. No test commands, CI dispatch, deployment, or data migration were initiated as part of this patch.

## Source changes

- New `functions/school-admin-security.js`: school-scoped scrypt password verifier with fresh Firebase school-login proof for enrollment/recovery, failed-attempt lockout, change/unlock, short-lived action-bound grants, audit records, and one-use Drive approval consumption.
- `functions/managed-schools.js`: managed/admin/security handler after existing Firebase identity and device verification. `managed/storage/connect` consumes a matching one-use Drive authorization when a school has enrolled a separate Admin Password. Schools without enrollment retain their existing compatibility path.
- New `lib/windows_admin_security.dart`: independent Admin Panel gate after App Lock; short-lived school-bound in-memory panel session; enrollment, password change, recovery, and action authorization UI.
- `lib/main_windows.dart` and `lib/main_dashboard_screen_windows.dart`: dashboard, direct device-management and student-import routes gated; Admin Password card appears in Password Management; logout and idle expiry clear the in-memory panel session.
- Windows UI requests a fresh independent Admin Password before saving the managed Google Drive connection, deleting a student/teacher, forcing promotion, toggling the force-promotion policy, and deactivating non-teacher staff.

## Six password options in Password Management

1. **Admin Panel Password:** mandatory Admin Panel gate, separate from App Lock; school-wide for managed schools, per-profile for standalone PCs.
2. **Student Records:** existing optional section lock retained.
3. **Fees Collection:** existing optional section lock retained.
4. **Exam Center:** new optional section lock and dashboard/sidebar password checks.
5. **School Expenses:** existing optional section lock retained.
6. **Attendance:** existing optional section lock retained.

Legacy section passwords migrate on verified unlock from locally encrypted plaintext to salted PBKDF2-HMAC-SHA256 with 120,000 rounds. Newly set section passwords require 8–128 characters. Legacy six-character passwords remain usable to avoid locking out existing schools. Existing section passwords are currently per-PC; the separate managed Admin Password is shared across the school's authorized PCs.

Managed and standalone passwords are checked again before a section-lock preference can be changed or disabled, Drive editing is enabled, a person is deleted, force promotion is requested, or staff is deactivated. The managed Drive connect broker consumes its own one-use approval.

A draft, **unexecuted** Node test suite exists in `functions/test/school-admin-security.test.js`. Tests and Flutter builds have not been run.

## Important safety boundary — not yet complete

**Person deletion and force promotion are protected at the Windows UI confirmation boundary, NOT yet universally enforced as separate server authorizations across every underlying Cloudflare/Drive/legacy sync route.** The current person and promotion approvals are logged and explicitly consumed once by the backend before the Windows UI begins a sensitive local mutation; they are NOT attached to the durable original sync operation. A malicious/older client that already has a valid school-admin credential can potentially invoke backend mutations without this second factor. Do not describe this patch as end-to-end permission complete.

Do not abruptly require short-lived grants at `managed/records` or Cloudflare direct-record paths: existing offline/retry/outbox operations can remain pending for longer than a grant, and this would stall or invalidate valid original operations. The follow-up must design an exact school+actor+operationId+record-generation+record-revision binding, guarantee durable approved intent before local delete, cover each broker/Worker/GS mutation path (including batch and legacy), preserve idempotent replays and repair, and provide a migration for existing pending operations. Force-promotion writes require approved original exam/result/target ownership too. Non-teacher staff currently uses active/inactive in `school_settings/staff_payroll_directory` rather than a person-delete API.

Standalone Windows profiles now use a separate per-profile, salted PBKDF2 Admin Password with their own Admin Panel gate. A previously saved legacy Admin-section password can be verified and migrated. Unlike managed credentials, these local credentials are deliberately PC-local; without managed school ownership verification, forgotten standalone Admin Passwords cannot be silently reset with App Lock. Managed schools depend on the backend being deployed before the Windows UI is rolled out. Without backend connectivity the independent managed Admin Panel cannot be unlocked. Existing open screens are not forcibly closed on another PC's password change; the new credential version is rechecked at the next admin navigation, and privileged actions request a fresh password. Immediate push revocation of already-open screens remains to be implemented. The approval TTL storage policy must be separately configured in Firestore if automatic removal is desired (handler already enforces expiry even without TTL cleanup). Immediate revocation of already-open screens, and strict server enforcement over the original durable delete/promotion outboxes, are still pending.

## Required future approval/acceptance — do not run without user order

1. User-approved static/build, Dart analyzer, server unit/security tests and CI to catch compile and integration regressions. The added Node tests must be actually executed and errors corrected.
2. One-school, two-PC test of enrollment, independent App Lock, Admin unlock, password change/recovery, lockout, idle/logout, school switching and direct-route checks.
3. Drive initial connection/replacement with expired, reused, wrong-school, and mismatched-URL approval; verify existing school Drive identity/root/files remain unchanged on rejection.
4. Add durable, server-enforced delete and force-promotion approval across all sync paths; prove pending older operation recovery, offline reconnection, Cloudflare ACK, multi-PC propagation, rollback and audit.
5. Staging rollout after tests; separate explicit approval before any merge, production deployment, or mass credential migration.
