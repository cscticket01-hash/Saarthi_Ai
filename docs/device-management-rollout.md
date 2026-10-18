# Device management rollout

This change adds the compact Windows device table and a separate server opt-in,
`SAARTHI_DEVICE_MANAGEMENT_ENABLED=true`. Default behavior stays unchanged.
This flag does not enable TEST signed offline leases or change licence expiry.
The existing isolated TEST enforcement flags and signing requirements still apply.

Management mode requires fresh password sign-in to register each PC, retains the
five-PC transactional limit, and checks registry authorization on every protected
online request, including the existing presence heartbeat. Revoke preserves local
records; an offline PC cannot receive immediate logout. Activity means a heartbeat
within two minutes, not proof that the app is currently online.

Deployment order:
1. Verify the Windows build and management-mode integration tests.
2. Publish the compatible Windows version before activating the server flag.
3. Ensure school PCs have upgraded and can sign in again. Old clients do not
   understand management-only registration. Unregistered PCs cannot use online
   routes after activation. Do not activate silently on existing installations.
4. On an isolated test school, verify two-PC registration, list/current markers,
   heartbeat, cross-PC revoke, revoked-PC rejection and preserved local data.
5. Activate only after reviewing this migration impact and verifying the actual
   service source commit. A successful CI run alone is not live verification.

Rollback: restore the previously verified server configuration/release. Disabling
management restores legacy online authorization, including access for revoked PCs;
this security consequence must be considered. Registry/audit data need not be deleted.

The UI never fabricates devices when rollout is disabled or a response is invalid.
Refresh requests run only while the page is visible; existing application heartbeat
is reused. Live activity becomes unknown on failed refresh and revoke stays disabled until
verified data returns. Screenshots produced by widget tests use synthetic records.

## Stable directory and activity display

The Windows page now keeps a display-only directory cache scoped to the exact
API endpoint, school ID and account UID. Cached names remain visible across page
reopening or an unavailable API. Cached activity is never green and cached data
cannot authorize Revoke. Freshly verified responses update keyed rows in their
existing order; background reads do not show a full-page loading bar. Green/gray
status and last-seen labels age locally without calling the school-data sync engine.
Only device-list polling runs while this page is visible; the existing heartbeat
continues unchanged. A failed read retains names and last-known authorized count,
clearly marks the saved list unverified and disables Revoke.

A disabled rollout is still a server deployment/configuration issue, not an empty
directory. Do not fabricate registrations or enable enforcement globally to hide
that error. The live saarthi-oauth-staging service was observed on backend commit
b219b1a1967b874c17a1abfde32bbd2fe94b98d8, predating management-only mode.
Deployment/activation must follow the compatible-client and fresh-sign-in steps
above; the stable UI fix does not certify live multi-PC enrollment.
