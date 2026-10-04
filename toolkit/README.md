# Saarthi Test Lab

A separate **Windows app with a local browser dashboard**. It runs on your PC;
it is not a public website. All new source is in `toolkit/` on `test-toolkit`.
The main branch, production apps, Firebase project, school backend and publishing
workflows are not changed.

## Start

Download the `Saarthi-Test-Lab-Windows` GitHub Actions artifact, unzip it, then open
`Saarthi-Test-Lab.exe`. The dashboard opens on a random `127.0.0.1` port. The server
is bound to loopback and protects API calls with a per-launch session token.
Use **Exit toolkit** to close it. Closing a browser tab alone does not stop a run.

From source, install Python 3.11+ and double-click `toolkit/start_lab.bat`, or run:

```sh
cd toolkit
python run_lab.py
```

On first launch the app genuinely creates **100,000** SQLite test students,
including unique IDs, class/roll pairs and cryptographically random QR identity
tokens. Progress is the number actually persisted. Interrupted generation resumes;
existing identities are not replaced. It does not create 100,000 remote Firebase
documents merely by opening the app.

## Experiments

- Choose any quantity **1–100,000** and a starting student number.
- Set worker concurrency, journey arrival rate, timeout and a P95 time limit.
- Choose one or several tests. Tests run sequentially; each has its own measured report.
- Backend login/attendance needs no manual QR entry. The same QR identity fields are
  supplied automatically to the school's normal login endpoint. This simulates app
  requests, **not** 100,000 Android phones running their cameras.
- Student-add runs use a new roll/ID cohort so you can repeat quantity experiments.
- Actual elapsed time, average/P95/P99 journey latency, throughput, real HTTP
  requests, successful/failed journeys and saved-data verification are reported.
- Preparation and verification have separate durations. Request latency includes
  login when its school session was not already cached.

### Status meanings

| Status | What it means |
| --- | --- |
| NOT RUN | No run exists; measurements are blank. |
| RUNNING | Actual execution/preparation/verification is in progress. |
| PASS | Every selected journey/check succeeded and the configured P95 limit passed. |
| FAIL | A real request, data assertion, duplicate check or time limit failed. |
| BLOCKED | Credentials, test backend, licence/calendar, device or runner setup is missing. |
| INCONCLUSIVE | Requests completed but saved-data verification could not be completed. |
| CANCELLED | Stopped early; accepted remote writes are retained. |

HTTP 200 alone is never treated as an attendance/student-save PASS. Attendance
verification reads the school's Firestore records and audits duplicate logical
identities. Student-add verifies matching Firestore **and** Google Sheets data.
Fee tests check receipt count, duplicate receipts and the actual total paid amount.
Website HTTP tests require expected content so an error/login page cannot pass merely
because it returned 200. They do not claim browser rendering was measured.

## Connect the targets

**School backend:** Download Test Lab → Connections → Test-backend setup bundle.
When the website's public Google OAuth verification is pending, use **Check Firebase
only** first. It uses Email/Password Auth and verifies an actual Firestore read without
Google sign-in or an Apps Script URL. The bundle includes `grant_test_admin.py` for
setting and verifying the test administrator's claim in your own Google Cloud Shell,
using your owner login without a service-account private key. Firebase-only connection
does not enable attendance/student/fees tests: those still need the verified test backend.
Follow its `SETUP.md` to provision a separate school Firebase/Apps Script/Drive.
Only test/lab project IDs with the enabled toolkit bridge are accepted. A normal
test-school administrator account and real trial/licence are still required.
Choose a range for remote preparation; the reusable 100,000 base stays local.
Current cloud quotas can prevent a large run; quota failures are recorded honestly.

**Website:** Set a preview/site URL and expected HTML text for real HTTP load.
For actual screen journeys add a browser success selector, optional developer login
and JSON actions (`click`, `fill`, `assert_text`). Flutter web accessibility/semantics
must expose usable labels/selectors; an unavailable selector fails or blocks the run.
The website and licence project are hardcoded in the existing source; a fully isolated
website/licensing test needs a separately configured test build. This toolkit does not
patch or deploy your original app or website to make that happen.

**Windows app:** Set a **test-copy** EXE and JSON UI actions. The runner uses real
Windows UI Automation, records actual step times and sampled process RSS memory,
and launches/terminates only its own process. Separate APPDATA/LOCALAPPDATA are used.
Native secure storage and machine-bound licensing still require a test build/VM;
environment variables alone do not guarantee full isolation. The UI assertion must
check the relevant screen/count if you want to validate a large student-data load.
Native screen scenarios use one process/device and report actual configured steps,
not the global synthetic-student quantity. See `scenarios.example.json` for shapes;
control labels must match your installed build. Missing controls do not pass.

**Android app:** Set ADB, exact device/emulator serial, optional test APK and
package/activity. APK installation, launch timing, configured UI assertions,
screenshot and available process PSS are measured on the real device. Supported
actions: `tap`, `keyevent`, `tap_resource`, `assert_resource`, `assert_text`.
No device is silently selected. Bulk QR login happens at API level automatically;
camera scanning/GPS hardware need an actual suitable emulator/device UI scenario
and are not claimed proven by API tests. Offline-sync correctness likewise requires
a configured native scenario and outage setup; there is no prefilled offline PASS.

The executable includes optional browser/Windows runner libraries. Use Connections →
Install browser runner to download Chromium once. Source users can install:

```sh
python -m pip install -r requirements-web.txt -r requirements-windows.txt
python -m playwright install chromium
```

## 10 GB data volume

Choose **Data volume · local** or **Data volume · Drive**, then any size up to **10 GB**
(decimal GB = 1,000,000,000 bytes). These tests write actual random bytes in 1 MB
chunks; no sparse files or fake file sizes. Each saved chunk is actually read back and
SHA-256 checked. Files/manifests are retained, including after Stop. The initial
setting is 0.01 GB so nothing writes 10 GB without your selected run.

Local results explicitly say **Toolkit storage only**. Drive results identify the
isolated school Drive. Neither result is presented as proof that the Windows/Android
UI can search/render a 10 GB dataset; run the configured app-screen scenario as well.
Firebase is used for text records; large binary files stay local/in Drive.

## Reports and data

The app stores its generated base, reports, exports and captures under
`%LOCALAPPDATA%\SaarthiTestLab`. Firebase administrator credentials/session tokens
remain in process memory and are excluded from configuration reports. QR exports
include synthetic test identity tokens, so keep them in your test environment.
There are no predetermined demo outcomes in the working app.

One local runner supports up to 512 active workers. 100,000 records or journeys is
not a claim of 100,000 simultaneous real devices. Peak active workers, actual sent
HTTP requests and completed journeys are recorded. Cloud quotas, script locking,
network, disk and generator CPU can all limit a run.

## Build and verify

```sh
cd toolkit
python -m unittest discover -s tests -v
```

`toolkit-checks.yml` runs unit/integration and browser checks, builds the isolated test
backend, and produces a Windows EXE artifact. It needs no repository/Firebase secrets,
never deploys, never creates a GitHub Release and never modifies main. For a local
Windows EXE build, run `build_windows.bat`.

Protocol/runtime references: [Firebase Auth REST](https://firebase.google.com/docs/reference/rest/auth),
[Firestore REST](https://firebase.google.com/docs/firestore/reference/rest/v1/projects.databases.documents),
[Apps Script quotas](https://developers.google.com/apps-script/guides/services/quotas),
[Playwright](https://playwright.dev/python/docs/intro),
[Windows UI Automation](https://pywinauto.readthedocs.io/en/latest/getting_started.html),
[ADB](https://developer.android.com/tools/adb),
[PyInstaller](https://pyinstaller.org/en/stable/usage.html).
