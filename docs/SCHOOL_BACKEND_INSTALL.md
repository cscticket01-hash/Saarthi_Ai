# Install the corrected school Firebase and Google backend

These files update the backend supplied by the owner. School scripts and rules must be installed in each school account; the central
website deploys through the repository workflow.

## Files to copy

| File | Destination |
| --- | --- |
| `school-backend/SaarthiSchool.gs` | Replace the old full school Apps Script code |
| `school-backend/SaarthiMobile.gs` | Add a second `.gs` file in the same script project |
| `school-backend/SaarthiStorage.gs` | Add a third `.gs` file in the same script project |
| `school-backend/SaarthiPlatform.gs` | Add a fourth `.gs` file for free licensing, summaries and owned FCM |
| `school-backend/appsscript.json` | The script manifest, shown through Project Settings |
| `school-backend/firestore.school.rules` | The **school's** Firebase Console → Firestore → Rules |

There must be exactly one `doPost` and one `doGet`. The complete `SaarthiSchool.gs`
already calls the mobile adapter; do not add another router. Do not install the
school rules in the central developer Firebase project. Central rules stay in
`firestore.platform.rules`.

## Prepare each school separately

1. Keep the school's existing Firebase email/password account. Give only its
   trusted administrator UID the `admin: true` custom claim (or `role: "admin"`).
   An ordinary or anonymous Firebase login is deliberately insufficient. The
   existing manual **Set School Admin Claim** GitHub workflow can set the claim
   when its school service-account credential belongs to the chosen project.
   Do not paste private keys or service-account JSON into public repository code.
2. The Apps Script owner must have access to that school's Firebase project.
   Enable the Firestore API and grant that Google account the Datastore User role
   in that exact project. The manifest includes Sheets, Drive, Datastore and
   external-request, Firebase Messaging and Script trigger scopes. Authorise them when running setup.
3. Run this function from the script editor, substituting the school's own
   public Firebase Web API key and project ID:

   ```javascript
   function setupThisSchool() {
     return VS_setupSchool('your-school-project-id', 'your-school-web-api-key');
   }
   ```

   It creates a unique school Drive folder and returns its ID. Copy that ID for
   inspection in Drive. A configured script cannot be rebound to another
   Firebase project; use a separate script project for the next school.
4. **Existing school:** locate that school's legacy spreadsheets and top-level
   photo/document/receipt/profile/report folders in Drive. Copy their exact IDs
   from their URLs. Run the following migration once, replacing the examples:

   ```javascript
   function migrateThisSchool() {
     return VS_prepareSchoolStorage({
       fileIds: ['EXACT_STUDENT_SHEET_ID', 'EXACT_TEACHER_SHEET_ID'],
       folderIds: ['EXACT_STUDENT_PHOTO_FOLDER_ID']
     });
   }
   ```

   Include **all** existing school sheets: students, teachers, fees, expenses,
   documents index, school profile, both attendance sheets, exams and results.
   Include all its top-level media folders. Omit categories the school has never
   used. Confirm every ID belongs to this school before running. The helper
   moves those items into the school's root; their IDs, contents and URLs remain.
   Items already marked as belonging to another school are rejected.

   **Brand-new empty school only:** run
   `VS_prepareSchoolStorage({startEmpty: true})` instead. Do not use this option
   to skip migration for a school that already has data. Until preparation is
   confirmed, data actions fail rather than returning an empty sync snapshot.
5. Compare the migrated sheets and row counts with the old data before installing
   the new app build. Apps Script now searches only its school folder, even when
   multiple schools use the same Google account and identical filenames.
6. Install `firestore.school.rules` in that school's Firestore. Sign out/in in
   Windows to refresh its administrator claim. Keep the correct Firebase and
   script URL together. Old unprotected scripts are rejected by the new Windows
   identity handshake.
7. Create a **new web-app deployment version** of this script, execute as the
   deploying owner and allow anyone to reach the endpoint. Keep the existing
   deployment URL when updating its version. Public reachability does not give
   access to school records: Windows needs verified school-admin proof and
   Android needs its own hashed, expiring school session. QR data never contains
   an administrator password, Firebase ID token or owner OAuth credential.
8. Deploy the central Spark rules/website, enable Anonymous sign-in for immutable
   trials, then connect Windows,
   set school location/calendar, and regenerate student/teacher ID cards. Each QR
   must contain this school's Firebase project, script URL and person link token.
9. In the developer website Schools section, generate this school's monitoring
   setup. Copy `VS_setupPlatform({...})` into a temporary setup function in the
   school editor and run it as owner. Keep its password in script properties only.
   The website also generates the school-bound licence key; activate it in Windows.
10. Register the universal Android package `com.example.saarthi_ai` in this school's
    Firebase. Run `VS_setupMessaging(androidAppId, projectNumber)` with that school's
    values and authorise the new scopes. Enable its FCM HTTP v1 API and grant its
    script owner messaging-send permission. Update the web-app deployment version.
    Full steps and quota/online-count definitions are in [PLATFORM_SETUP.md](PLATFORM_SETUP.md).

Instead of four `.gs` tabs, the `school-backend-copy-paste` review artifact contains
one combined `Code.gs` plus the manifest and school rules. Install **either** the
combined file **or** the four source tabs, never both. The old bundle from the
previous Functions-based release is not compatible with this free backend.

## What was fixed

* Public student/notice reads and the unauthenticated parent-contact update were
  removed. Ordinary Firebase users no longer become school administrators.
* The new calendar, attendance, exam and salary collections have explicit rules.
  Mobile session documents and all unlisted/nested collections remain denied to
  Firebase clients. Audit records stay append-only; app update metadata stays
  client read-only.
* Every legacy Google POST action verifies the school administrator's complete
  Firebase ID token through Firebase, checks its project/expiry/role and rejects
  disabled or revoked logins. The promotion adapter checks the school sync ID too.
* Windows identity requests now carry fresh administrator proof. A redirect
  cannot carry that proof to an unrelated host. Successful responses must report
  the currently connected school's project.
* Windows and script-owner Firestore writes remove media fields recursively.
  Local/Drive copies remain intact; operational text, amounts, marks, dates and
  secure QR/session identifiers still sync.
* Mobile ID photos/logo are fetched through the authenticated school endpoint
  from its own Drive folder. An arbitrary requested file/person ID cannot choose
  the image; the pupil's name and DOB must match its school sheet. The mobile
  school profile returns only display/location fields, never connection settings.

Firestore rules protect client requests. Apps Script uses the owner's OAuth/IAM
access, which bypasses those rules; its request guards and media filter are also
required. Keep the owner's IAM access and script properties private.

Legacy uploads in the supplied backend use `ANYONE_WITH_LINK` for some Drive
photos/receipts. Folder separation does not revoke those existing sharing links.
The authenticated mobile route also works with private files, but the existing
Windows URL previews still rely on link sharing. Treat copied Drive links as
shared files; app login protection cannot make a public Drive link private.

## Verify before using live data

Use two test schools, including two scripts under the same Google account.
Confirm separate sheet/folder IDs and that School A's admin token, QR or session
cannot read School B's records. Test wrong class/roll/DOB, an unauthenticated
student directory read and parent-contact update, and a reused student roll.
Verify photos come from Google while new Firestore documents have no media
fields. Compare migrated rows, close a calendar date, try both attendance roles,
and preview student/teacher IDs and report cards.

Automated tests cover the full supplied Apps Script router, scoped Drive lookup,
explicit migration, administrator/session checks, media filtering and Firestore
rules in an isolated emulator. Real project IAM, deployment versions and old
Drive sharing permissions must still be checked in the school's actual setup.
