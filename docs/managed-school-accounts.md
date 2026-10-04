# Managed school account / school-owned GS storage — review implementation

No deployment, release, billing/IAM changes or automatic existing-school migration.
Base: Windows 2.1.90 source 2735447. Existing local database, profile isolation,
Advanced Settings GS URL, document/QR renderers and sync outbox are reused.

## Identities and authority

One central Firebase project: saarthi-ai-df12b. Developer-only server creates
Firebase Auth email/password accounts, random School IDs and server-owned UID
memberships. Password setup/reset uses Firebase links; no password is returned,
stored in Firestore, compiled into clients or copied into a script. Username
aliases are not shipped in this first implementation; email is the login ID.
Five-day school trial is created once server-side. Paid/licensed access requires
activation of the exact school-bound hashed key. Entitlements and stored public
licence status are verified live. Block/disable/revoke prevents server storage
operations independently of Windows UI. Admin SDK endpoints enforce membership
and developer identity because Firestore Rules do not authorize Admin writes.
Managed memberships cannot use legacy central API or direct operational Firestore
paths. Existing legacy memberships/rules remain compatible.

## Storage, reuse and safety

Managed school records are JSON files within that school's Drive, synchronized
through the existing Windows local cache/outbox; large files are separate private
Drive files. Firestore holds only accounts/licences/mapping/status/protected
connection references. Existing Sheets and existing Firestore/Drive records are
not automatically imported, moved, deleted, reset or rebound. Existing legacy
installations retain their working mode. Switching account selects a separate
local tenant profile. Pending sync uses its original Firebase token and expected
schoolId; switching credentials cancels the old work. Local writes/profile changes
are serialized, and stale document references, batches and transactions reject
mutation after a school switch. Existing Google session is preserved separately when first
entering managed login. Once used, managed login remains required after logout;
logging out cannot fall back to legacy local licence Skip.

The supplied Pasted text(2).txt contains the existing main GS and older adapters.
Its main spreadsheet/Drive helpers are retained in the generated all-in-one GS;
the new managed protocol uses private JSON records for the Windows local model.
It does not pretend old sheets have been migrated into this model. A later
reviewed import is required for an existing school changing storage architecture.

The bundle is school-backend/managed/SaarthiManagedAll.gs, generated using
.github/scripts/build_managed_script.py from the existing main GS and managed
adapter. Public doPost only verifies HMAC requests; legacy endpoints are not
exposed in this bundle. No monitoring password, datastore, Firebase Messaging or
trigger permission is needed by the managed storage adapter. Manifest requests
Drive and spreadsheets scopes; these are different from Desktop drive.file.
Google authorization and deployment must be done with the SCHOOL Google account.
Never deploy all scripts as the developer's account and assume school ownership.

Requests are signed by the server, tenant-bound, timestamp-limited and replay
protected with persistent nonces under a script lock. The server accepts exact
registered script.google.com /exec URLs and only Google's script.googleusercontent
redirect. A signed probe checks the script School ID before activation. Connection
secret is AES-256-GCM encrypted server-side; no client can read the private registry.
File reads verify ancestry inside the exact school root; no public-link sharing.
20 MB file/backup limit, 512 KB individual JSON record limit, 20 MB collection
export limit. Google quotas may require batching for larger schools; no unlimited
capacity claim. Backup schema 3 restore accepts the same school/root, validates
identity and creates only missing records; existing records are skipped. Multi-file
restore is resumable but not transactional. No physical/live restore test done yet.

## Review enablement and subsequent manual acceptance

New account UI requires SAARTHI_SCHOOL_CLOUD_URL in the website build. Managed
Windows review sets SAARTHI_MANAGED_ACCOUNTS=true; legacy production build is not
released. Live server deployment has NOT occurred. Before any deployment approval,
review server routes, set SAARTHI_MANAGED_ONLY=true to require developer creation for new schools (existing legacy memberships remain usable), exact CORS origin, Firebase email/password provider and
account-creation access, server admin IAM, and a server-only 64-hex
SAARTHI_MANAGED_STORAGE_KEY. Do not paste that key in the website/Windows/GS.
Use an existing secure server; no Firebase billing/Functions activation needed.

After deployment is explicitly approved: developer creates school/account; school
sets password using setup link. Developer/school owner pastes all-in-one GS and
manifest in THAT SCHOOL'S Apps Script. For a genuinely new connection run
VS_setupManagedSchool('vs-...', {startEmpty:true}); retain returned root and
connection secret. Existing storage requires exact verified root/import review;
startEmpty is never an automatic migration. Deploy as school owner, then developer
registers exact /exec URL and secret on website. Windows Advanced Settings reuses
its existing GS URL field and verifies it matches developer binding. No new
Firebase project, school API key or service-account file is required.

Monitor is developer-only, read-only Cloud Monitoring descriptor/time-series
retrieval. Missing permissions/services/data are displayed as unavailable, not
zero or invented capacity. Response time measures that API request, not internet
speed. Live Firestore quota limits use the read-only Service Usage quota API when the existing credential has access; otherwise unavailable is shown.
No API activation or IAM/billing mutation is performed by monitoring.

## Validation and outstanding live acceptance

Backend isolation/account/expiry/block/HMAC/tampering/replay tests and existing
backend regressions. Firestore emulator tests deny managed direct operational
access, foreign data, protected configuration and secret registry. Windows/web
review build and existing document/date/startup/GPS regression suite.
Pending explicit deployment approval and real school-owner Google authorization:
new accounts A/B, password reset/disable, block existing session, licence expiry,
GS root cross-access, Drive file/backup/restore, app restart, local cache separation,
loss of network, and actual monitoring IAM/data. Offline verification failure
pauses managed UI; no 72-hour licence grace or normal-work Skip in managed mode.
