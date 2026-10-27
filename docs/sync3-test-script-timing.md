# Isolated TEST Apps Script write-path latency instrumentation

**Scope:** TEST Sync V2 school `vs-db8afb01a3be46a983c8284714d06e5d`, isolated synthetic `school_notices` version-2 **writes only**. Existing main/production branch and deployed real-school scripts are not changed by this GitHub commit.

## Measurements

Only the *successful authoritative Apps Script response* to an eligible write contains `testScriptTiming`:

- `lockWaitMs`: waiting to acquire the original Script lock.
- `sheetSearchMs`: total wall time inside the verified per-ID Sheet lookup function, including readback lookup and any partition fanout.
- `sheetWriteFlushMs`: canonical `setValues` + `SpreadsheetApp.flush` time.
- `finalVerificationMs`: authoritative saved row readback and equality check.
- `postVerificationMs`: sync head, JSON backup, readable Sheet projections; helps explain residual Script time.
- `totalScriptMs`: overall Script execution duration as observed inside `VS_managedRecord` up to completion of the durable record adapter.
- `storageMode`: `sheets`, `partitioned_sheets` or `json`. For `json`, `jsonReadCommitMs` measures the JSON storage adapter; **Sheet-specific fields are not applicable, not proof of zero-cost storage**.

Durations use wall-clock milliseconds and may overlap (e.g. search during readback is included in both `sheetSearchMs` and `finalVerificationMs`). **Do not add the component values** to obtain total time. Browser/device/network latency is separate. No record IDs, PII, credentials, raw request bodies or student data are logged or returned in the timing object.

## How to collect REAL values

1. Check and **safely install the reviewed source** in the existing, isolated TEST Apps Script project. Creating the GitHub commit alone does **not** install or deploy an Apps Script version. Never update a real school's script.
2. Preserve existing isolated TEST script properties, school identity, Drive, and version/exec URL. Avoid changing storage authority, manifest scopes, license or data.
3. Execute one new, synthetic, version-2 `school_notices` write through the existing authenticated TEST broker, retain its original versioned ACK, and capture `testScriptTiming` plus broker `syncTiming.scriptRoundTripMillis`. If absent, mark `NOT DEPLOYED` rather than guessing.
4. Repeat only with a few bounded *unique* synthetic records after confirming each ACK and no pending operation, never with 400-school load. Report p50/p95 and lock/search/write/verify values with exact storage mode.

Source safeguards: the original Script lock and 30-second wait are unchanged; existing index matching, revision CAS, receipt verification, storage write/flush, backup/readback, record IDs and queuing are untouched. Only test diagnostics are appended to already successful acknowledgements.

## Known current limits

Real latency acceptance run `40332689751` attempted 95/100 records and ended with one TEST outbox operation pending; 90 had completed Android/website readbacks. It does not supply any internal Script stage metrics. The newest real **Apps Script version must be installed** before the new measurements exist.
