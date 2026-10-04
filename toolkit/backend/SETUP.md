# Isolated school test backend

This bundle is for a **separate test school**, never an existing operational school.
It includes copies of the repository's four school scripts and an administrator-only
toolkit adapter. It does not update the original school scripts, apps or central website.

1. Create a Firebase project with `test` or `lab` as a separate part of its project ID,
   for example `saarthi-lab-school`. Enable Firestore and Email/Password Auth. Set the
   test administrator's `admin: true` custom claim. Install the supplied school rules.
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
