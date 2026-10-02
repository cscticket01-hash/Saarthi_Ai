# Windows school Google Connect — unpublished preview

This change adds an optional setup wizard in Advanced Settings. It preserves existing school connections, Android code, website code and
backend source. This branch also contains the previously implemented offline
startup and unrestricted licence Skip fixes. Do not publish or merge until the live acceptance checks below
are completed with an authorized test school account.

## What this build does

Two entry buttons: **Connect Google Drive** and **Connect Firebase**. Drive setup
also prepares Firebase first, so both links always belong to the same school.
The administrator confirms new empty school storage, chooses Mumbai/Delhi, signs
in to their school Gmail in the system browser and grants permissions.

The wizard creates a new, labelled Google project, adds Firebase, enables the
required APIs, creates the default Firestore database, applies the repository's
school rules, enables password sign-in after Google's initial Auth setup, creates
a dedicated school admin credential and verifies actual Firestore access. The
school configuration is filled automatically; no URL copying is required.

For Drive it creates a school-owned Apps Script project, uploads an asset generated
from the canonical school backend, creates a version/deployment, discovers the
web-app URL and verifies school identity, admin protection and accessible storage
before saving the connection. It uses the existing school-isolation/sync engine.
No local fallback can falsely satisfy setup verification.

Progress is encrypted in Windows secure storage and bound to the Google account's
stable subject ID. Retry resumes that account's project. Cancel stops requests;
it does not delete resources already created. Uncertain non-idempotent script
creation stops for recovery instead of blindly creating a duplicate. App reset
clears the local setup checkpoint under the existing reset prefix, but never
deletes school cloud resources. **After reset, connect existing resources through
manual settings; starting a new setup does not recover an old cloud project.**

## Honest limits: this is guided setup, not silent provisioning

Google may require first-time terms acceptance, permission grants or quota checks.
The app cannot approve these for the school.

1. Each account must enable Apps Script API access in its Google user settings.
   The wizard opens the exact page if access is denied.
2. Firebase Authentication may require **Get started** in Firebase Console. The
   wizard does not call billing-only `initializeAuth` or upgrade the project.
3. The school opens its generated script, selects `VS_easyConnectSetup`, clicks
   **Run**, and grants script permissions. The generated helper supplies project
   IDs and API keys, so no code editing/copying is needed. It prepares only the
   explicitly confirmed new school folder. Return to the app and click Continue.
4. If Google does not expose a web-app entry point from API deployment, the owner
   must deploy once as Web app / execute as owner / access Anyone. The app then
   discovers that URL automatically. Organization policies can prohibit this.

This first preview supports school **Gmail** accounts and **new empty cloud
setups**. Existing cloud data migration, Workspace/domain accounts, recovery after
reset, Android Firebase app/FCM registration and messaging triggers are not
automated here. Existing setup paths remain intact. There is no promise of
unlimited quotas or fully automatic notification onboarding.

## One-time developer prerequisite

A real **Desktop application OAuth client** is required. The repository public Client ID is supplied by the developer. No real school
Google account has yet been used here to provision resources.
Without it, the wizard clearly displays “Developer setup is pending” and disables
sign-in. It never claims to have connected anything.

Create/configure the Google OAuth consent application with Cloud Resource Manager,
Service Usage, Firebase Management, Firestore, Firebase Rules, Identity Toolkit and
Apps Script APIs enabled as appropriate in the OAuth application's project.
Configure the requested scopes: `openid`, `email`, `cloud-platform`,
`script.projects`, `script.deployments`. Complete Google's consent/verification
requirements before external school rollout; testing-mode accounts must be
explicitly allowed. These permissions are powerful: disclose them to schools.

Supply at Windows build time:

```
--dart-define=SAARTHI_GOOGLE_DESKTOP_CLIENT_ID=<desktop-client-id>
```

Installed desktop clients are public clients. OAuth client secrets and
service-account private keys are never compiled into this executable. Authentication uses system-browser OAuth, loopback
127.0.0.1 with an ephemeral port, random state and PKCE S256. Privileged Google
access tokens exist only in memory and are not sent to Apps Script or the developer
website. No Google refresh token or Google password is saved. The generated
per-school Firebase password/checkpoint is encrypted locally and cleared on reset.

Both Windows workflows pass only the public OAuth Client ID. This PR does not
run the release workflow, change published releases, attach billing or deploy
Cloud Functions.

## Verification and release gate

Automated coverage: PKCE/state handling, cancellation/browser failure, mocked token
exchange, API endpoint/redirect restrictions, sanitized API errors, account-bound
resume, project collision protection, no-billing Auth approval, script permission
retry/uncertain creation, deployment rediscovery, backend school mismatch and
storage verification, and disabled UI without developer configuration.

CI runs these alongside Windows/Web builds and existing platform regression and
school-rules checks. `python tool/build_school_setup_bundle.py --check` prevents
uploaded script/rules drifting from canonical school source. Regenerate with the
same command without `--check` after approved backend changes.

Before release, a developer must use a real configured Desktop OAuth client and
an authorized empty test-school account to verify consent, each actual Google API
response, Auth initialization, Firestore rules/admin login, script execution and
deployment, interruption/resume, Drive pairing, reconnect after app restart and
cross-school denial. Test both Google buttons. Confirm Spark/no billing and inspect
actual school resource ownership. Automated mocks do not replace this live test.
**Until these checks pass, production readiness is not established.**

## Official references

- https://developers.google.com/identity/protocols/oauth2/native-app
- https://developers.google.com/apps-script/api/how-tos/enable
- https://developers.google.com/apps-script/api/reference/rest/v1/projects.deployments
- https://firebase.google.com/docs/projects/api/workflow_set-up-and-manage-project
- https://firebase.google.com/docs/firestore/reference/rest/v1/projects.databases/create
- https://firebase.google.com/docs/rules/manage-deploy
- https://cloud.google.com/identity-platform/docs/reference/rest/v2/projects.identityPlatform/initializeAuth
- https://cloud.google.com/identity-platform/docs/reference/rest/v1/projects.accounts/lookup


## Continuation: verified status, safe reconnect and preview builds

The wizard shows separate Google account, Firebase, Firestore, Google Drive and
school storage statuses. A service is marked connected/ready only after its
corresponding verification completes during this session. Saved checkpoint flags
alone never show a verified connection. OAuth expiry or cancellation clears the
current setup authorization; sign in again with the same school account to resume.
Changing accounts cannot adopt the previous school's project or credentials.
Google refresh tokens are intentionally not retained; reconnect requests fresh
consent. Existing Firebase refresh tokens remain in the existing secure store.

OAuth token exchange and user-info requests refuse redirects. Invalid Google
response bodies are never surfaced in error messages. Admin resume checks the
exact generated UID/email, blocks disabled accounts and preserves unrelated custom
claims. Resource lists follow pagination and script deployment retries reuse the
saved version rather than creating a new version on every attempt.

For an unpublished configured Windows test build, run **Platform review builds**
with the optional public `google_oauth_client_id` input, or set the repository
variable `SAARTHI_GOOGLE_DESKTOP_CLIENT_ID`. The installed client uses PKCE and does not embed or send an OAuth client secret.
The repository secret stays in GitHub; CI checks only its presence as a boolean.
The Windows review job requires a valid public ID and runs a compiled Dart
configuration test using the same definition as the Windows build. No release
or deployment is performed by this PR workflow. Live Google token exchange must
still be tested with the configured Desktop client; a successful compile does
not prove consent or resource provisioning works.

School steps: Advanced Settings → Connect Google Drive → Connect School Cloud → enter school name,
choose India location and confirm new empty storage → sign in with the school
Gmail account → grant access → follow any Firebase/Apps Script approval screen →
Continue → wait for all verification statuses → Done. Selecting Connect Firebase
performs only the Firebase half; return to Connect Google Drive with the same
account to finish storage setup. Existing schools keep their manual connections;
automatic setup refuses to replace them.

Remaining acceptance: supply the real Desktop OAuth client, approve a test-school
account in the consent application if it is in testing mode, then run the live
new-school/interruption/reconnect/revocation tests above. Automated mock tests and
builds cannot establish that Google's actual consent and provisioning work for a
particular organization. Workspace migration, recovery after app reset and mobile
notification onboarding remain outside this preview.
