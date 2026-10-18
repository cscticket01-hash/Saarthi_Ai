# Safe device-directory rollout

## Phase 1: compatible enrollment and activity only

Deploy the reviewed backend with `SAARTHI_DEVICE_ENROLLMENT_ENABLED=true`.
Leave `SAARTHI_DEVICE_MANAGEMENT_ENABLED` and TEST enforcement off.
Normal school session, storage, record sync and offline licence authorization
retain their existing behavior. Do not enable the full access gate globally just
to remove a DEVICE_ROLLOUT_DISABLED message.

The compatible app advertises `deviceManagementProtocol: 2` on fresh school
password sign-in. Registration requires active verified school-admin membership,
entitlement and fresh authentication, and keeps the transactional five-PC limit.
Retries retain the same credential/device identity. Older clients receive the same
explicit disabled-rollout registration response that their existing login handles.
Existing sessions continue syncing without being forced out or clearing queues.

A PC must complete one fresh school sign-in in the compatible app to enroll.
Unregistered devices cannot obtain a verified directory. No fabricated names or
counts are shown. Other logged-in PCs keep normal school access. The existing
presence heartbeat optionally records registered-PC activity asynchronously;
directory-storage failures cannot fail the original presence ACK. No additional
school-data sync or heartbeat timer is introduced.

In this phase the server returns `canRevoke: false`; the UI explains and disables
Revoke. It must not pretend revocation blocks access while the access gate is off.
Activity means a heartbeat within two minutes, not proof of physical power state.

## Phase 2: enforce device access when school PCs are ready

After compatible clients enroll and their list/heartbeat have been verified,
activate `SAARTHI_DEVICE_MANAGEMENT_ENABLED=true`. Every protected online request,
including presence, then verifies the registry. Revoke is enabled in this phase.
Local records, pending operation identities and existing offline licence policy
remain preserved. A disconnected PC cannot receive immediate logout. Strict TEST
signed offline enforcement remains separate with its existing isolated-school
scope and Ed25519 signing requirements.

Before activation, verify the exact live backend source, compatibility of school
PCs, and two-PC enrollment/list/activity/revoke on an isolated test school.
CI success alone does not certify live multi-PC access. Do not silently activate
the full gate on unregistered working school PCs.

Rollback: disabling the full gate restores legacy online authorization, including
access for previously revoked PCs. Consider that security consequence. Registry,
audit records and school data need not be deleted or reset.

## Stable directory display

The display-only cache is scoped to API endpoint, school ID and account UID. It
stores device metadata only, never tokens/credentials. Cached names stay visible
across page reopening and unavailable API responses. Cached activity is never
green and cached data cannot authorize Revoke. Verified responses update keyed
rows in their existing order. Background reads show no full-page loading bar and
do not disable otherwise authorized buttons. Old reads cannot undo a newer revoke.
Failed reads retain names/last-known authorized count, mark activity unverified
and disable Revoke. Local status/time labels age without school-data sync calls
or repeated unchanged repaints.

The live saarthi-oauth-staging backend was observed on
b219b1a1967b874c17a1abfde32bbd2fe94b98d8, predating these rollout modes.
A compatible backend deployment is required to remove the operational 503.
No production configuration/deploy is changed by this pull request.
