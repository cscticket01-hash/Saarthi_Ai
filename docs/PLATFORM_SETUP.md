# Developer website, Windows school app and universal Android app

The website source is the developer control centre for vidyasaarthi.web.app. Existing
Firebase email/password credentials are retained. The central account needs the
existing `admin: true` claim or `developer: true`; school accounts cannot generate
keys or read the central dashboard. Windows, QR login and school script setup also
reject the developer project as an operational school database.

## Review before publishing

The Platform review builds workflow compiles the web, Windows and Android entry
points and runs the backend and PDF tests. Download its three build artifacts:
`developer-website-preview`, `windows-review-build`, `android-review-apk`.
The review APK uses a debug certificate and must be installed as a test build.
Production uses the existing permanent Android signing key and package name.
The review workflow never deploys, publishes releases or modifies Firestore.

Publishing main runs the website and signed app release workflows. The website
workflow tests both school and central Firestore rules, verifies Anonymous Auth,
then deploys **Firestore rules and Hosting only**. Cloud Functions, Cloud Run,
Cloud Build and Blaze are not required by this design. `functions/platform.js`
is retained for regression coverage of the previous API; it is not deployed or
called by the current clients. Billing is never upgraded automatically.

The existing deployment account needs Firestore rules/Hosting access and Firebase
Authentication Admin if Anonymous sign-in is not enabled yet. Already-enabled
Anonymous sign-in is verified through its public API without requiring config-read access. This
changes only that provider; existing developer Email/Password accounts stay intact.
If the account lacks Auth config access, enable Anonymous in Firebase Console and
grant the deployment account the stated role before retrying. School monitor
accounts use the existing Email/Password provider and have no developer claim.

## Connect each school's own backend

1. Each school keeps its own Firebase project, Google Apps Script, Drive and sheets.
   Use the school's own administrator Firebase login in Windows Advanced Settings,
   then save that school's Apps Script /exec URL. The Firebase user must have an
   `admin: true` or `role: "admin"` custom claim in that SCHOOL project.
2. Follow [SCHOOL_BACKEND_INSTALL.md](SCHOOL_BACKEND_INSTALL.md) to install the
   corrected full `SaarthiSchool.gs`, companion `SaarthiMobile.gs` and
   `SaarthiStorage.gs` and `SaarthiPlatform.gs`, school Firestore rules and complete `appsscript.json`.
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
to a hashed Windows MachineGuid. The school trial retains that original device
start when it first binds to its own Firebase project; reinstallation does
not reset a previously registered device's trial. Clock rollback is rejected.
After expiry, the license gate permits only activation and protected connection
settings. Paid installations have an offline lease of at most 72 hours and never
past the key's expiry. A cached licence cannot carry into another school profile.

The developer generates a school-bound key from Licences and manually shares it.
The full key is displayed once; the central database stores its hash and a short suffix.
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

Only administration metadata is held centrally: school definitions, immutable trial
creation dates, licence hashes/renewal dates/purchase status, aggregate school counts,
and app complaints. The website provisions an Auth identity mapped to exactly one
school. Its script can publish only that school's numeric summary and support reports;
it cannot read the dashboard, list licences, issue keys, or write another school's data.
Student records, QR/session identifiers, marks, fees, media and FCM tokens stay at
that school. Complaints include the user's voluntarily submitted message, school,
role and app version; no directory record is attached automatically.

A summary is sent at most once per school every five minutes. `reportedAt` is the
central server timestamp; `lastSeenAt` is the school's last Windows/mobile activity.
The maintenance timer does not make an unused school look active. Active/inactive
uses a 24-hour activity window. Online students are a recent-activity **estimate**
from school-only cache shards; cache eviction can lower the estimate. Summaries older
than ten minutes contribute no online users. Registered student/app-user totals are
school-side count aggregations, not 30,000 central session documents. Warnings cover
licences expiring in the next 14 days.

Windows and Android submit complaints through the authenticated school script.
A private school outbox retains them during outages; a five-minute trigger retries.
Five reports per person per day and one central report per school per 30 seconds
limit writes. The developer can mark reports open, in progress or resolved.

## School setup and owned notifications

In website **Schools → School setup**, enter the school name and its separate
Firebase project ID. Copy the generated `setupSchoolMonitoring()` helper and run it
as the owner in that school's script. Remove the temporary helper after it runs;
the credentials remain in private script properties. Credentials appear only at creation; they
are not embedded in QR cards or either app. Generating setup again revokes the old
monitor identity's access; paste the replacement into the school script. The
function installs one five-minute maintenance trigger. For a school detected
through its trial, the first licence may return both a key and a setup bundle;
copy both. Then give the key manually and activate it in the school's Windows app.

In the **school Firebase**, register an Android app with the existing package
`com.example.saarthi_ai`. Use its Android app ID and project number from that
school's google-services.json to run:

```javascript
VS_setupMessaging('1:YOUR_PROJECT_NUMBER:android:YOUR_APP_ID', 'YOUR_PROJECT_NUMBER');
```

The school API key configured by `VS_setupSchool` must allow the school's Firebase
Installations/Messaging APIs. If API key restrictions are enabled, include the
Android package and permanent production certificate SHA-1:
`76:24:14:31:E2:A8:21:D7:56:64:A6:12:24:46:EB:50:6F:CA:D0:1B`.
Enable the school's Firebase Cloud Messaging HTTP v1 API. Its Apps Script owner
must have permission to send in **that school project**, and authorise the manifest's
Firebase Messaging and Script trigger scopes. No Cloud Function/service-account
private key is put in a school app.

The universal Android app initializes its default Firebase Messaging SDK with the
selected school's public Android options, including before background delivery.
On a project change it saves the new authenticated session and restarts its process,
which prevents an old Messaging singleton from retaining the previous project.
The compiled central google-services resource is not used to initialize messaging.

Windows relays a synced school notice through that school's authenticated script.
The script sends a topic invalidation through that school's FCM project, with **only**
school ID, notice ID and type. The phone immediately shows a generic school-notice alert; private text is fetched
through the authenticated school session when the app opens. Foreground dashboards
refresh on the signal. A broadcast to thousands of sleeping phones therefore does
not create thousands of simultaneous Apps Script/Firestore requests. Knowing a public
Firebase config/topic cannot reveal private notice content. Queued messages from
another school are ignored; logout unsubscribes, deletes the token and clears notices.
Background delivery needs Android notification permission and a non-force-stopped app.

Production APK signing/package identity are retained. Android checks this repository's
static `android-update.json` GitHub Release asset, so routine update checks
do not consume central Firestore reads or GitHub API requests. Windows releases
do not replace the latest Android release. SHA-256 is verified before opening the APK;
updates do not depend on the discontinued central API.
The existing public Android update metadata remains readable for completed releases.
Windows retains its GitHub-based installer/update system. Preview builds do not
publish production update metadata.

## Free capacity and remaining installation work

The design targets at least 10 schools and 30,000 **registered** students across
separate school projects. A 10-school central summary schedule has a maximum of
2,880 summary writes/day, plus licence/support/trial operations. Rule lookups,
Windows licence checks, school licence checks and dashboard reads also consume
central reads. School operational activity consumes each school's own quotas.
This is a quota-oriented design target, not a 30,000-concurrent-user benchmark or
an unlimited/free-forever promise. Per-school Apps Script concurrency/URL Fetch
and Firebase daily quotas still apply. The monitor summary test uses 10 school
records representing 30,000 students; it is not a production load test.

School Apps Scripts/rules and their Firebase Android registrations must be installed
in their respective accounts. This repository cannot deploy to unprovided school
accounts. Download the review's `school-backend-copy-paste` artifact for combined
`Code.gs`, `appsscript.json` and `firestore.school.rules` (exactly one doPost/doGet).
Do not reuse the earlier three-file bundle; its licence API was the old Functions design.

## Acceptance check

Use two test Firebase projects with different script URLs. Verify that School A's
key and QR are rejected for School B, wrong student DOB fails, each student sees
only their own marks/fees, and changing school stops previous notices. Close a date
and try attendance as both roles; neither should write. Save non-final marks and
check no class movement; final FAIL must retain; final PASS and authorised override
must promote. Check all template previews and selections. Verify a signed update
on an already-installed production APK, not only a fresh install.
