# Daily mobile attendance and school schedule

The Windows Attendance & school calendar page has a three-dot menu immediately
left of Students / Teachers. Schedule saves the active school's recurring student
opening and closing times in `school_settings/attendance_schedule`. Times use
Asia/Kolkata (IST); opening is inclusive and closing is exclusive. Disabled means
no time window. School calendar closures still apply. Teacher self-attendance is
once per day, without the student time window.

The mobile attendance screen offers a single daily capture. The existing SQLite
outbox is the source of the local lock, keyed by endpoint, School ID, role,
person ID and India date. The first committed capture locks the day in every
state, including pending, needsAttention and completed. A transactional check
prevents concurrent captures. Restart/logout does not delete the lock or original
capture. Remote recorded status also locks a fresh device after school readback.
Server queue identity continues deduplicating the same school/person/day/entry.
Old queued check-outs retain their original IDs and continue through the existing
worker; the new mobile screen cannot create new check-outs.

The mobile schedule is read from its authenticated school response, backed by
the school Script's signed policy. Window checks run before local capture, in the
broker's permit path and again against that school's current configuration in
the Script. Pending retry does not call the capture gate. Delayed delivery checks
the retained capture timestamp rather than the worker delivery time. An exact
already-committed operation returns its receipt even if the schedule changed.
A changed policy may require school review for an uncommitted capture; original
queue data is retained. Existing date/permit expiry checks remain unchanged.

The active profile is fenced across Windows async reads and schedule dialogs;
a school change cannot save an old dialog into the next school's settings.
No school name, pupil or real-school ID is hard-coded. All school storage,
licence/session checks, GPS rules, original approvals and queue ACK guards remain.

## Compatibility and rollout

This change needs matching Windows/mobile clients, the broker, and the canonical
school Script bundle `2026-10-19.1`. Health advertises
`attendanceScheduleVersion: 1`; the mobile response exposes schedule version 1.
A student client with missing/old schedule support asks the school to update and
does not silently assume unrestricted attendance. An updated Script with no
schedule configured retains unrestricted times until the school enables one.

Recurring cached schedules can be used within the existing verified offline
access rules. The remote recorded flag applies only to its reported day. A new
India date reloads the local lock. Offline clients cannot learn changed schedules
until reconnection; authoritative Script checks may then retain a capture for
review. Client capture time remains device-reported, not a trusted hardware clock.

## Verification

- Full Node backend suite: 501 passed, zero failed.
- New Script tests exercise opening/closing boundaries, delayed in-window delivery,
  exact operation replay after a changed schedule, duplicate rejection, teacher
  independence, invalid windows and foreign school lease rejection.
- Signed broker tests exercise policy projection, window denial before enqueue,
  delayed capture, queue deduplication and a foreign-school permit.
- Added mobile SQLite tests cover pending/review/completed locks, reopen,
  concurrent capture, role/school/day separation and IST boundaries.
- Added Windows widget regression prevents an open Schedule dialog from writing
  into another school after a profile switch.
- Flutter attendance, mobile sync, Windows operations and Windows portal suites:
  73 passed, zero failed, with an isolated APPDATA folder matching CI.
- Changed-source analysis: zero errors; nine warnings/info in the broader source
  files. Strict analysis of the schedule helper and attendance store: no issues.
- No native Windows release build, Android APK, physical school device or
  production deployment has been exercised by this change.
