# Retained real-day acceptance handoff

The original acceptance task authorizes the deadline-gated rejected restore
probe for this disposable isolated TEST fixture. Observation alone cannot
certify expired-restore rejection. Neither path permits recreating the fixture,
retiming it, deleting it or purging retained evidence.

## Fixed baseline

- School: `vs-db8afb01a3be46a983c8284714d06e5d`.
- Fixture: `recycle-expiry-v1-20261011-resume-acceptance`.
- Deletion revision: `26d0800c-5f42-4022-bfc2-a959bc5c3c9a`.
- Original server deletion: `1791680719426` milliseconds.
- Original server deadline: `1791767119426` milliseconds.
- Earliest real expiry: **12 October 2026 06:35:19.426 Asia/Kolkata**
  (**01:05:19.426 UTC**).
- Original baseline artifact: `11688200206`, run `38100482579`.

Existing automation `6acaf5e00b4c8191938554fa5b77148d` is scheduled for
12 October 2026 06:36:20 Asia/Kolkata. Update that task's checkpoint rather than
creating another task. Recheck actual PR24 HEAD, exact deployed TEST runtime and
available supported invocation at execution time; historical CI is not current
runtime proof.

## Observation

1. Use existing secure isolated-TEST authentication. Do not display credentials,
   bearer tokens, private file IDs or account content. Missing supported access
   means BLOCKED; do not bypass account restrictions.
2. Confirm authenticated `managed/session` identifies the fixed TEST school.
3. Read `managed/records`, operation `read`, collection `school_notices`,
   protocol2. Verify the fixed fixture is still a tombstone, its school and
   `_syncOperationId` match, and its revision matches the baseline.
4. Read `managed/recycle`, operation `list`, collection `school_notices`.
   Traverse bounded pagination to find that same entry; inability to find it
   is FAIL/BLOCKED, never permission to recreate it.
5. Compare `deletedRevision`, `deletedAt`, `recoverUntil` with the original
   baseline exactly. Verify `recoverUntil - deletedAt == 86400000`, the row's
   recycle deadline matches, and audit retention remains true.
6. Use actual authenticated `serverNow` to require
   `serverNow >= 1791767119426`. Earlier observations remain
   WAITING_REAL_ELAPSED_DAY. After the boundary require entry status `expired`.
7. Retain sanitized source/runtime/time and comparison evidence, with
   `expiredRestoreRejected: UNVERIFIED` for this read-only procedure. A successful
   observation certifies only the same retained fixture's elapsed-day expiry.

## Authorized complete acceptance invocation

`test_recycle_live.cjs` mode `check-expiry` is the authorized complete gate.
After actual server expiry it attempts one expected-rejected restore against the
same snapshot/revision, then rereads and compares the unchanged tombstone and
retained audit. It never enters the `start-expiry` creation/deletion branch.
It requires the fixed baseline before probing and never permanently purges.
Run the existing `recycle-test.yml` workflow on the actual reviewed TEST source
with these dispatch inputs:

```text
mode: check-expiry
fixture_id: recycle-expiry-v1-20261011-resume-acceptance
deleted_revision: 26d0800c-5f42-4022-bfc2-a959bc5c3c9a
deleted_at: 1791680719426
recover_until: 1791767119426
```

The existing workflow job guard accepts `feature/smart-sync-3`, not
`feature/smart-sync-3-finalization`; verify that TEST branch contains the reviewed
source first. Never default to `restore`, use `start-expiry`, or push a branch
solely to invoke the fixture-creation job. GitHub connector currently exposes no
workflow-dispatch operation; if no supported authorized invocation is available,
report BLOCKED rather than rerunning the old baseline job. A future automation
must inspect tools again because availability may change.

Expected full-gate evidence: actual `serverNow` at/after the original deadline,
`elapsedDayVerified: true`, rejected restore HTTP502 and
`SCRIPT_OPERATION_FAILED`, unchanged tombstone, identical baseline revision and
deadline, `auditRetainedAfterProbe: true`, and `expiredRestoreRejected: true`.
A sanitized provider failure does not prove the exact private exception cause;
the before/after retained-data comparison is required. Physical devices and
original-school diagnostics remain outside this acceptance.
