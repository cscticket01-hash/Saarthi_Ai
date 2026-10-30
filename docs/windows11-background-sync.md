# Windows 11 background Sync Engine — controlled logon startup

## What is implemented

The standard Windows portable/runtime Flutter desktop app already retains
hourly, push-notification and local-mutation scheduling while **minimized**.
This rollout adds a *single-instance, background-at-Windows-sign-in* mode:
the official Inno installer offers the checked-on-first-install optional
**"Automatically sync Vidya Saarthi in the background after Windows sign-in"**
task. It creates a current-user Startup-folder shortcut to the **same**
signed Windows app executable with `--saarthi-background` (not a separate
worker with new storage). Nothing is installed as SYSTEM or with admin rights.

After **interactive Windows sign-in**, the shortcut launches one hidden Flutter
engine. The same authenticated school/session, SQLite store, outbox, one-hour
idle reconciliation, instant delta dispatch and verified ACK logic continue.
Launching Vidya Saarthi normally reveals this existing window. The generated
Win32 native runner holds the existing per-session mutex from before the
first Flutter engine; any second launch exits and **never** opens the same
school SQLite database. There is no duplicate financial request from a
second app process. It is a normal per-user background application, **not** a
Windows service.

The installer option can be disabled during setup or the shortcut disabled
in Windows Startup Apps. A portable ZIP has no automatic startup registration.
This is not permission to auto-start the app when it is installed on a new
school before a verified school account is registered.

## 24-hour license/device authorization (TEST/staged until released)

Running in the background **does not** bypass the existing school licence,
App Lock, entitlements or device proof. The authenticated server
`managed/session` check refreshes the 24-hour interval when it succeeds.
Background presence and Sync Engine use the same verified session and
throttled checks. A connected Wi-Fi icon, ordinary ping and failed
request do not extend the lease. At expiry the local dashboard remains
visible but input is disabled, then an informative network disclaimer
appears after three seconds. All new sync batches are blocked and durable
pending work stays queued. On a successful new session verification the
controls and sync admission can resume automatically, still within
license/device limits.

The 24-hour policy is separately **opt-in** and the server signing window
must match the build. Do not enable it on production with a 15-minute
device enforcement lease. A real-school rollout requires TEST success and
documented approval.

## Windows 11 limitations and evidence

- **Minimized / hidden app**: remains a desktop process, subject to power
  management and Windows/App Lock/local-data policies. If the PC is awake
  and authenticated, network operation is possible.
- **User explicitly exits the app**: the process stops. It is restarted by
  the selected Startup shortcut on the **next Windows sign-in**; it is not a
  persistent service and does not instantly respawn after an intentional exit.
- **Log out / shutdown / sleep / hibernate / suspended process**: no guaranteed
  Dart timers or real-time uploads. The original durable outbox resumes on
  next application start/wake. A sleep-prone PC will not achieve continuous
  sync merely by installing this shortcut.
- **No internet / revoked or expired licence / wrong school**: never silently
  ACK or delete queued writes.
- **Physical acceptance required**: Windows 11 real desktop:
  installer-selected Startup shortcut -> reboot/login -> no visible window;
  second normal launch -> exactly one restored window/process;
  minimize -> remote notice and fee delta -> matching cloud readback;
  offline/reconnect -> existing original operation ID and one final ACK;
  locked session, App Lock timeout, 24-hour lease, expired fee records,
  sleep/wake, 1/2/5 PCs, update/uninstall and user opt-out.

The hosted workflow runs Python native-source checks and a real Windows
runner smoke test that starts hidden, checks window visibility, reveals
from a second launch, checks process uniqueness and restart. This does **not**
replace an authorized real-school Drive/Sheets acceptance run. Do not mark
the rollout production-ready until those conditions are met.
