# Isolated school test backend

This bundle is for a **separate test school**, never an existing operational school.
It includes copies of the repository's four school scripts and an administrator-only
toolkit adapter. It does not update the original school scripts, apps or central website.

## Connect Firebase while public Google verification is pending

The toolkit signs in to Firebase using Email/Password and verifies an actual
Firestore read through security rules. This does not use the website's Google
sign-in, OAuth client or branding verification. It does not create a Firebase project
automatically. Complete these owner steps once for a separate test project:

1. Create a Firebase project with `test` or `lab` as a separate part of its project ID,
   for example `saarthi-lab-school`. Enable Firestore and Email/Password Auth. Set the
   default Firestore database to your chosen region. Create a test administrator in
   Authentication → Users and publish the supplied `firestore.school.rules`.
2. Open [Google Cloud Shell](https://shell.cloud.google.com/) as this project's owner.
   Upload the bundle's `grant_test_admin.py` (Cloud Shell menu → Upload), then run:

   ```sh
   python3 grant_test_admin.py --project saarthi-lab-school --email YOUR_TEST_ADMIN_EMAIL
   ```

   Replace the example project and email with your own test project and administrator.
   The helper uses Google's built-in `gcloud` owner authorization, grants `admin:true`,
   preserves other claims and reads the account back. It needs Firebase Auth user get/
   update permissions in the explicit test project. It never switches the active
   gcloud project, deploys anything, or asks for a service-account private key.
3. Copy this test project's Web API key from Firebase Project settings. In Test Lab →
   Connections, enter project ID, Web API key and test administrator email/password.
   Click **Check Firebase only**. The `/exec` URL may remain empty at this stage.
   Firebase is marked verified only after real Auth, admin-claim and Firestore-read
   checks succeed. Incorrect credentials, absent claims and denied rules do not pass.

Firebase verification is a connection check, not an attendance/app performance result.
Student attendance/add/fees still need the separate Apps Script backend below.

## Connect the separate school backend

1. First complete the Firebase owner setup above.
2. Create a new Apps Script project. Paste `Code.gs`; replace its manifest with
   `appsscript.json`. The script owner needs access to this test Firebase project and
   its Firestore API. Use the normal school-backend setup requirements in the repo.
3. As owner, run `VS_setupSchool('TEST_PROJECT_ID', 'TEST_WEB_API_KEY')`, then
   `VS_prepareSchoolStorage({startEmpty:true})` for this new school's **empty** Drive.
   Run these calls inside a temporary owner-only setup function in the script editor.
   Follow `docs/SCHOOL_BACKEND_INSTALL.md` for the normal setup requirements.
   Do not point the test script at real school sheets or folders.
4. As owner, run `VS_toolkitEnableTestMode()`. Only project IDs containing `test`/`lab`
   are accepted. Set this test school's own `school_location` and calendar settings.
5. Deploy this new script as a web app, execute as owner, allow anyone to reach its
   endpoint. Data actions still require verified school administrator/student proof.
6. Enter this Firebase project, its Web API key, administrator login and the /exec URL
   in Test Lab → Connections. Connect & verify must report `testOnly: true`.

This new script has its own owner authorization, separate from your website's public
OAuth app. Google's documented unverified-app flow permits personal/development use
subject to account policies and user caps; Workspace policies may still block it.
Do not change your production website's OAuth publishing status or client for this.
If script authorization is blocked, Firebase can still be checked independently,
while school-backend scenarios truthfully remain BLOCKED.

The normal student handlers still enforce licence/trial, calendar, QR/session and
location checks. A valid test-school trial/licence is required; the toolkit never
forces these checks to pass. It does not automatically register a school centrally,
issue a key, deploy a project, or publish a website. Complete the existing test-school
licensing/setup flow through your normal administration process.

`toolkit_seed` prepares matching synthetic Firestore **and** Sheets identities and
reads both back. Bulk traffic then uses the **original** `mobile_login`,
`mobile_mark_attendance`, `add_student` and fee handlers. Verification reads actual
persisted records; it never echoes request quantities as saved results.

The adapter additionally audits duplicate attendance, verifies Sheets/fees, and writes
test Drive chunks with an actual SHA-256 file read-back. It has no data-deletion API.
Keep created test files in the test school's Drive, and remove them there when done.

Repeated attendance check-in for the same student/date is expected to be rejected by
the real backend. Use another student range or another open test date to measure a new
successful cohort. A duplicate rejection remains FAIL; it is not silently accepted.

References: [Firebase Email/Password REST sign-in](https://firebase.google.com/docs/reference/rest/auth#section-sign-in-email-password),
[owner account lookup](https://cloud.google.com/identity-platform/docs/reference/rest/v1/projects.accounts/lookup),
[owner account update](https://cloud.google.com/identity-platform/docs/reference/rest/v1/projects.accounts/update),
[Apps Script OAuth client verification](https://developers.google.com/apps-script/guides/client-verification).
