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

## Windows UX and URL-only GS connection review (October 4)

- Removed the duplicate Windows School Cloud managed page and the automatic Google/Firebase connection card. Advanced Settings retains the existing Gmail and `/exec` URL integration, verified status and a real Drive backup action.
- Trial banner retains its expiry and licence link; its Sign out action is removed. Account logout remains in the existing admin sidebar.
- The app no longer rebuilds its entire dashboard every second before expiry. The timer only gates expiry/stale verification; overlapping heartbeat checks are coalesced. Email/password typing disables suggestions/autocorrection and password edits no longer rebuild the login form for a character count.
- A saved central school session still receives server verification at startup and every 30 seconds. App Lock is checked on managed restart; Admin Section Lock is independently checked before the direct dashboard. Locks are scoped to the managed school on shared PCs; legacy keys remain untouched. Managed idle expiry reopens enabled local locks without Firebase logout; without enabled locks it renews the local idle window. Explicit account logout still requires school sign-in. App Lock can be set/changed/disabled independently of the Firebase school password and Admin Section lock.
- For a NEW, already school-bound managed GS storage deployment, the operator pastes only its `/exec` URL into Windows. The authenticated broker generates a one-use 120-second ticket internally; GS verifies it against the fixed central broker and its existing School ID/root before returning the secret to the broker. The broker then verifies an HMAC health request, rechecks school access and transactionally saves the encrypted secret. Neither Firebase credentials nor connection secrets are returned to Windows. Existing storage cannot be replaced from this flow.
- Scripts without this updated managed adapter cannot use URL-only pairing. The school script owner must update its existing deployment with `school-backend/managed/SaarthiManagedAll.gs` and the manifest. `script.external_request` is required for the ticket callback. Keep the existing `VS_MANAGED_SCHOOL_ID`, `VS_MANAGED_ROOT_ID` and `VS_MANAGED_SECRET`; do not reset/rebind existing storage. A new script must first be prepared once for the School ID through the existing `VS_setupManagedSchool` procedure.
- Pairing tickets are ephemeral per-process capabilities (no Firebase token/Firestore ticket data). A backend restart during pairing requires retry; it cannot authorize a stale ticket. This existing service uses one instance. A future multi-instance deployment needs shared short-lived tickets before enabling that topology.
- Real Windows IME/backspace behaviour, restart/lock flow and school-owned GS backup require testing on a Windows PC and the owner's deployed script. Widget/emulator/build results do not substitute for those checks.
