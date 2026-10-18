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
is reused. Counts become unknown on failed refresh and revoke stays disabled until
verified data returns. Screenshots produced by widget tests use synthetic records.
