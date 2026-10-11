# Smart Sync 3.0 isolated physical-device acceptance

Status: **UNVERIFIED physical hardware**. Hosted Windows runners and Android API 35 emulator results are distinct evidence. Use only TEST Sync V2 (`vs-db8afb01a3be46a983c8284714d06e5d`) and unpublished review artifacts. Never install over the original school PC/database. Record client artifact SHA, backend/Script versions, device/OS, UTC timestamps and elapsed time; retain sanitized operation hashes, counts and categories, not pupil data or credentials.

## Windows

1. On a separate TEST PC or VM, start a fresh profile. Authenticate TEST identity, restore a verified TEST local backup into separate staging, review manifest/school/count/queue results and explicitly approve activation. Restart and compare original record revisions, capture timestamps, queue operation hashes and media hashes. An incomplete/corrupt/wrong-school backup must leave the usable storage pointer unchanged.
2. Disconnect Wi-Fi; add three synthetic records including one document. Close and reopen offline. All three local records, original capture times, source media and pending operations must remain accessible. Reconnect and verify authoritative cloud readback for each original operation before it leaves pending. Submit a duplicate request and verify one logical cloud record.
3. Minimize the app and observe a **full elapsed 60 minutes**, without changing the OS clock. Record start/end and actual scheduled checkpoint timestamps. Confirm the UI remains usable and no overlapping provider calls occur. Separately sleep/wake and disconnect/reconnect Wi-Fi; record bounded scheduling/retry and retained pending data.
4. On isolated storage, terminate the TEST process after durable local save and during recovery staging. Restart; compare pending IDs and journal state. Repeat rapid Sync requests; verify engine serialization and no duplicate uploads. Inject only TEST server failures and verify typed 502/503/timeout states, bounded retry and cached UI access.
5. Keep one newer local edit pending during stale cloud readback. It must survive restart without forced ACK. Test financial/document restore refusal without approved authoritative coordination.

## Android

1. Keep Windows closed. Authenticate the same TEST school, disconnect network/enable airplane mode, capture synthetic attendance, then actually terminate and relaunch the process. Verify session/cache, pending operation identity and original capture time. Do not replace this with an in-process object reopen.
2. Disable airplane mode, reconnect Wi-Fi and wait for durable ACK plus cloud readback. Verify exactly one attendance row, then open TEST Windows and verify unchanged timestamp/revision. Repeat a duplicate submit and separately test Wi-Fi loss during an upload.
3. Force TEST HTTP 502/503 and timeout separately; display server/timeout messages without falsely declaring measured internet disconnection. Preserve verified offline school data and session. A foreign TEST-school identity must not retrieve the record or binary.

## Real 24-hour recycle acceptance

Do not alter clocks or backdate snapshots. Create and delete one disposable nonfinancial TEST notice through ordinary signed operations; retain the server-generated deletion timestamp, recovery deadline, delete revision and sanitized original operation hash. Read the retained snapshot and server time shortly before the deadline, then again after **at least 86,400,000 actual elapsed milliseconds**. Verify the exact same entry transitions from recoverable to expired, expired restore is rejected, audit evidence remains, and no automatic destructive purge occurs. Record the actual hourly scheduler execution timestamp separately. A completed hourly run with zero selected entries does not certify expiry of a real item. Existing successful recycle restore fixtures are not an elapsed-day test.

## Representative media acceptance

Use authorized synthetic or redacted examples of student/teacher photos, logo, signature, seal, handwriting, small printed text and multipage PDF. Save originals and optimized copies, record hashes/byte sizes, inspect faces/text at normal display and print size, then verify actual cloud byte readback and offline display after process restart. Remove only a disposable TEST cache copy and verify repair restores matching bytes. Corrupt a disposable TEST download and verify the previous usable file remains and failure is counted. Synthetic tiny-image readback and PDF text/QR tests establish integrity, not representative visual readability.

## Evidence gate

For every row record PASS/FAIL/UNVERIFIED, artifact/runtime identity, actual elapsed duration, authoritative ACK/readback and retained pending state. Hardware access and readable representative files are currently unavailable to this automated session. None of the procedures above is reported as executed physical acceptance. Production rollout remains blocked until required checks and explicit release approval are complete.
