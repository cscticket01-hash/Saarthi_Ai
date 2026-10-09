# Manual per-school Google Drive / Apps Script setup

The Windows app uses central Firebase for managed school login/licence and the authenticated School ID. Each school has its own Apps Script project, deployed by its own Google account, and its own Drive root. Local/offline storage stays intact. An old `/exec` endpoint alone does not prove school identity or implement the managed protocol.

## New school connection

1. Create the managed school account in the existing developer website and copy its exact School ID (`vs-` followed by 32 hexadecimal characters).
2. In that school's Google account, create a separate Apps Script project. Paste `school-backend/managed/SaarthiManagedAll.gs` as the combined code and use `school-backend/managed/appsscript.json` as the manifest. Do not keep duplicate doPost/doGet functions from an older script.
3. In the combined code set `VS_SETUP_SCHOOL_ID` to that school's exact ID and set `VS_SETUP_CREATE_NEW_STORAGE` to `true` ONLY for a genuinely NEW connection. This explicitly creates a separate school-marked Drive folder; it does not import existing legacy records.
4. Select `VS_prepareSchoolStorage` in the editor's function selector and Run. Authorize the script as the school account through Google's supported consent flow. No Firebase project/API key/service account is required from the school. The result contains readiness and School ID, never a connection secret.
5. Set `VS_SETUP_CREATE_NEW_STORAGE` back to `false`. Save and deploy as a Web app, execute as the school account that deploys it, access Anyone. The HTTP endpoint still requires the server's school-bound ticket/signature: anonymous access does not permit anonymous school operations.
6. Copy the deployed `/exec` URL. Log in to Windows with the website-created school account. Paste the URL into Advanced Settings and Save. The existing broker verifies the short-lived one-use ticket, matching School ID and signed Drive health before storing the encrypted connection. No secret needs to be pasted into Windows.
7. Verify School Storage readiness, add a test record and create a Drive backup. Repeat with a second school; foreign root, record and backup access must fail.

## Existing school deployment or legacy data

Inspect the owner's actual source and current configuration before changing a live deployment. Preserve `VS_MANAGED_SCHOOL_ID`, `VS_MANAGED_ROOT_ID`, `VS_MANAGED_SECRET` and every existing file. Do not change these properties, rerun startEmpty, enable new-storage creation, or overwrite a protected central storage connection.

For an already prepared managed script, update the existing project's code/manifest using the reviewed bundle; leave the setup constants empty/false. Running `VS_prepareSchoolStorage` validates/reuses the saved school identity/root without generating a new root or rotating a valid secret. Update the EXISTING deployment to a new version after deployment approval and keep its `/exec` URL.

If the existing root is missing, belongs to another school, or the project is a legacy-only deployment, stop for developer recovery/migration review. Do not treat a fresh empty Drive folder as a migration of existing school data. The actual project's editor link/source/configuration is required to resolve that case safely; never share its connection secret or account password.

## Current acceptance boundary

Automated tests validate preparation guards, school isolation, signed URL pairing, licence checks and backup ownership. Real owner consent/deployment, native Windows Save As/lock operation and real Drive backup/restore require live acceptance. Repository review builds are not live releases. Do not deploy or release without explicit approval.
