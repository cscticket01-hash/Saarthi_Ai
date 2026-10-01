# Developer website, Windows school app and universal Android app

The website at vidyasaarthi.web.app is now the developer control centre. Existing
Firebase email/password credentials are retained. The central account needs the
existing `admin: true` claim or `developer: true`; school accounts cannot generate
keys or read the central dashboard.

## Review before publishing

The Platform review builds workflow compiles the web, Windows and Android entry
points and runs the backend and PDF tests. Download its three build artifacts:
`developer-website-preview`, `windows-review-build`, `android-review-apk`.
The review APK uses a debug certificate and must be installed as a test build.
Production uses the existing permanent Android signing key and package name.
The review workflow never deploys, publishes releases or modifies Firestore.

Publishing main runs the existing website and signed app release workflows.
Website deployment first installs the central platform API and its rules. Firebase
Cloud Functions requires the central project to have the Blaze plan, its necessary
APIs enabled, and the existing FIREBASE_SERVICE_ACCOUNT deployment account to have
permission to deploy Functions and Firestore rules. There is no automatic billing
upgrade. If deployment is unavailable, the new website is not published.

## Connect each school's own backend

1. Each school keeps its own Firebase project, Google Apps Script, Drive and sheets.
   Use the school's own administrator Firebase login in Windows Advanced Settings,
   then save that school's Apps Script /exec URL. The Firebase user must have an
   `admin: true` or `role: "admin"` custom claim in that SCHOOL project.
2. Follow [SCHOOL_BACKEND_INSTALL.md](SCHOOL_BACKEND_INSTALL.md) to install the
   corrected full `SaarthiSchool.gs`, companion `SaarthiMobile.gs` and
   `SaarthiStorage.gs`, school Firestore rules and complete `appsscript.json`.
   The full backend already calls the adapter; keep exactly one `doPost`.
3. Migrate existing school sheets/folders by their exact IDs with
   `VS_prepareSchoolStorage`. Confirm empty storage explicitly only for a new
   school. Account-wide Drive filename searches are no longer used.
4. Run `VS_setupSchool("the-school-firebase-project-id", "the-school-web-api-key")` as the script owner.
   The owner needs Firestore access in that exact Firebase project; enable the
   Firestore API and grant the script owner's Google account the Datastore User
   role. Authorise the requested Google scopes.
5. Deploy a new Apps Script web-app version, execute as the school owner, allow
   access to anyone. Access to student data still requires a verified, hashed,
   expiring school session. Never share a service-account key or owner OAuth token.
6. School Firestore rules must allow its own administrators to sync the school
   collections. Deny anonymous reads and writes. Android does not access another
   school's Firestore directly; the school's own script verifies its session and
   returns only that person's records.
7. Save School Settings, including school location and attendance radius.
   Regenerate ID cards so their secure QR contains the matching Firebase project,
   own Apps Script URL, role, person ID and unpredictable mobileLinkToken.
8. Student scans that ID, then enters class, roll and DOB. Teacher scans their
   teacher ID. Attendance needs another scan of the person's own ID at school.

Without installing the extension in each school's own script, its existing script
cannot understand the new mobile actions. This repository cannot alter a school's
separate Apps Script automatically.

## Licence and trial

Windows starts a five-day trial on first use. Server registration binds the trial
to a hashed Windows MachineGuid and a school Firebase project; reinstallation does
not reset a previously registered device's trial. Clock rollback is rejected.
After expiry, the license gate permits only activation and protected connection
settings. Paid installations have an offline lease of at most 72 hours and never
past the key's expiry. A cached licence cannot carry into another school profile.

The developer generates a school-bound key from Licences and manually shares it.
The full key is displayed once; the server stores its hash and a short suffix.
School activates it in Windows. Licence issuance and revocation require verified
developer access. The mobile backend independently checks school expiry.

## Attendance and results

Attendance lists daily student/teacher check-in and check-out, with a school
calendar. Sunday is closed by default; an explicit open/closed override wins.
The school backend uses the Asia/Kolkata date and disables attendance on closed
dates for both roles. QR identity, session identity, location and duplicate
check-in/check-out are verified on the school server.

Mark an exam as Final when creating it. Saving its completed PASS/FAIL result
automatically applies the class decision: PASS moves to the next class; FAIL
retains the current class. An administrator can enable the force-promotion switch
in Advanced Settings, then use Promote on a retained student. Decisions are
idempotent for the same final exam. Class 10 is the current app's final class.
When the previous roll is occupied in the next class, a free roll is assigned.
The school sheet and Firestore are moved together; another pupil is never overwritten.
A concurrent conflicting change is shown as pending for a safe retry.

Legacy Windows actions require a verified admin token from that school Firebase project;
public QR connection details cannot authorise directory reads or writes.

Student history keeps a random, stable mobile identity and previous document IDs so
promotion does not reveal a different pupil's fees, attendance or reports.
The salary drawer is intentionally a placeholder; mobile shows only the logged-in
teacher's salary records when the school later adds them.

## Documents, metrics and support

Templates contains Default plus four choices per document category. Student IDs
and separately designed teacher IDs each include two landscape and two portrait
options. Report cards and receipts have four layouts each. Preview produces the
actual PDF, including the default; the selected layout is saved per school and used by its print/export
actions and Android documents.

Only platform administration data is held centrally: school identity, bound
backend URL, licence, installation/session verification, activity counts, app
version, notice delivery and submitted support complaints. Student directories,
marks, fee records, attendance, salary, photos and documents remain in each
school's own Firebase/Google backend.

Active school means a Windows heartbeat within 24 hours. Online student means a
verified mobile heartbeat within five minutes. Counts deduplicate person IDs within
their school. Licence expiry warnings cover the next 14 days. No demo counts are
displayed as real activity.

Windows and Android can submit app complaints; the developer can mark them open,
in progress or resolved. Schools do not read another school's complaints.

## Notifications and updates

FCM message delivery is free. The central platform sends notices only to verified
tokens belonging to the issuing school; it never uses a global all-schools topic.
Windows relays newly published notices while online. The server deduplicates
delivery by school and notice ID. Foreground notices show an in-app alert;
background notices use Android's normal notification tray after permission is
granted. Both paths verify the currently logged-in school before displaying a
data-only FCM message, so queued notices from an earlier school are ignored.
Logout clears displayed notices. A force-stopped phone cannot receive until the
app opens again.

The central function hosting still requires Blaze, and normal backend usage can
have costs above its free allowance; this is not a promise of an entirely free
backend. Switching school removes previous school notification sessions.

Production APK builds retain the existing signing certificate, package identity,
GitHub release and app_config/android_update publication. The Android update
screen compares installed and published build numbers and uses only this
repository's release download URLs. Windows keeps its existing installer/update
system. Preview builds do not write production update metadata.

## Acceptance check

Use two test Firebase projects with different script URLs. Verify that School A's
key and QR are rejected for School B, wrong student DOB fails, each student sees
only their own marks/fees, and changing school stops previous notices. Close a date
and try attendance as both roles; neither should write. Save non-final marks and
check no class movement; final FAIL must retain; final PASS and authorised override
must promote. Check all template previews and selections. Verify a signed update
on an already-installed production APK, not only a fresh install.
