# Managed school controls — review only

No deployment, release, billing/IAM change, or existing school data deletion.
Forgot-password/OTP work is excluded.

- Developer creates a school with a 12–128 character initial password. Only Firebase Authentication receives that password; Firestore, response, audit and dashboard do not retain it. Existing setup-link accounts remain valid.
- School delete archives metadata, denies entitlement/membership, disables Firebase login and revokes sessions. Drive, local records, existing licences and audit remain preserved. Legacy delete archives and sets the persistent block flag.
- Windows always requires central authentication; legacy credentials/settings cannot select a dashboard fallback. Authenticated schools retain their tenant-scoped offline database, but normal access requires an online server lease. Licence expiration closes normal operations; activation and sign-out remain available, with no Skip.
- Registration header is removed. Licence input sits below Confirm Password. Registration reauthenticates the central password and scopes completion files by school ID. It does not change/create a local substitute password.
- Managed licence Settings and the trial banner use the central licence activation API. Password changes reauthenticate against Firebase and require a fresh login afterward.
- Windows presence is server timestamped. Heartbeats are every 30 seconds; abrupt close/offline is observed after 90 seconds, plus up to 30 seconds for the student poll. Explicit logout/dispose sends disconnect best-effort. Mobile requests never renew Windows presence.
- Managed ID QRs select the existing exact central endpoint. Mobile calls are centrally checked for entitlement/block and Windows presence, then HMAC signed to the registered school script. The signed script uses existing person/class/roll/DOB, own-record and GPS checks adapted to that school's Drive JSON. The legacy per-project script is unchanged.
- Drive summary is server-verified, cached five minutes, and contains counts/bytes only. Traversal is bounded; incomplete size totals display "At least". Large files remain in school Drive.
- Developer portal has the requested six-column Schools table, Firebase and Admin Profile sections, real release download buttons, live school metadata listeners, and a persistent 30-minute inactivity logout countdown. Password changes require current Firebase credentials.
- Monitoring is read-only, cached 60 seconds and exposes actual sampled storage/traffic/operation/latency metrics and quota values. Missing IAM/API/metric data is Unavailable, not zero. Traffic is sampled bits/second, read/write rates are operations/second, latency uses the metric's reported unit. Google samples can be several minutes delayed.

## Required live acceptance after separate deployment approval

1. Deploy reviewed backend/web/native/mobile builds and update each relevant school GS deployment with the combined managed script. Retain the existing school ID, secret and Drive root; do not rerun startEmpty for an existing connection.
2. Developer creates a dedicated test school; verify login from Windows, registration and Settings password/licence activation.
3. Verify five-day expiry and server block prevent normal Windows/mobile operations; test School A credentials/QR/session against School B.
4. Close Windows and confirm Offline / Unable to connect within heartbeat timeout. Reopen and verify recovery.
5. Confirm real Drive summary/backup and monitor permissions/sample availability. No fake usage or bandwidth claims.

Managed mobile notifications do not require or silently create a per-school Firebase messaging project. Existing legacy messaging remains intact; managed background push setup is outside this change, while notices refresh from the authenticated school data.
