"""Read Flutter machine events, never infer repair proof from a success banner."""
import json
from pathlib import Path


REQUIRED_SUITES = {
    'autonomous_infrastructure_repair_test.dart',
    'document_worker_repair_test.dart',
    'universal_health_test.dart',
    'sync_recovery_policy_test.dart',
    'windows_sync_durable_admission_test.dart',
}


def passed_tests(log, expected_commit=None):
    suites, tests, completed, passed = {}, {}, set(), set()
    finished = False
    source_commit = None
    for line in log.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue  # Tool startup noise is not evidence.
        if not isinstance(event, dict):
            continue
        kind = event.get('type')
        if kind == 'repairEvidence':
            if source_commit is not None:
                raise ValueError('Duplicate source provenance')
            source_commit = event.get('sourceCommit')
        elif kind == 'suite':
            suite = event['suite']
            suites[suite['id']] = Path(suite['path']).name
        elif kind == 'testStart':
            test = event['test']
            tests[test['id']] = test
        elif kind == 'testDone':
            test = tests.get(event.get('testID'))
            if test is None:
                raise ValueError('Completion without a test start')
            if event['testID'] in completed:
                raise ValueError('Duplicate test completion')
            completed.add(event['testID'])
            if event.get('result') != 'success' or event.get('skipped'):
                raise ValueError('Failed or skipped evidence test')
            if not event.get('hidden'):
                passed.add((suites.get(test['suiteID']), test['name']))
        elif kind == 'error':
            raise ValueError('Test run contains an error')
        elif kind == 'done':
            if finished or event.get('success') is not True:
                raise ValueError('Incomplete or failed test run')
            finished = True
    if not finished or set(tests) != completed:
        raise ValueError('Missing run/test completion evidence')
    if expected_commit is not None and source_commit != expected_commit:
        raise ValueError('Evidence is not from the current checked-out source')
    if not REQUIRED_SUITES.issubset({suite for suite, _ in passed}):
        raise ValueError('Missing required owner/safety evidence suites')
    return passed


def has_test(passed, suite, name):
    # Group prefixes may be added by Flutter; require the full test suffix.
    return any(s == suite and (n == name or n.endswith(' ' + name))
               for s, n in passed)


def verified_actions(passed):
    owner = 'autonomous_infrastructure_repair_test.dart'
    universal = 'universal_health_test.dart'
    result = set()
    if has_test(passed, owner, 'restart-monitor-timer: real heartbeat owner recovery and pause denial'):
        result.add('restart-monitor-timer')
    if all(has_test(passed, universal, name) for name in (
        'owner timer automatically repairs only its verified local schedule',
        'owner timer respects user-disabled schedules and school changes',
        'owner timer failed verification never claims repair success',
        'report timer repair retains authorization latch and does not send immediately',
    )):
        result.add('restore-owner-timer')
    for action in ('restore-admitted-dispatch', 'restore-checkpoint-deadline',
                   'restore-health-delivery', 'restore-context-observer'):
        if all(has_test(passed, owner, action + ': ' + suffix) for suffix in (
            'admission, repeat, school, pause, verification and restart budget',
            'failed owner restoration cannot become Healthy',
        )):
            result.add(action)
    if 'restore-admitted-dispatch' in result and not has_test(
        passed, owner, 'dispatch restoration respects withdrawn admission and current retry floors'
    ):
        result.remove('restore-admitted-dispatch')
    if 'restore-checkpoint-deadline' in result and not has_test(
        passed, owner, 'elapsed captured checkpoint restores once through owner dispatch'
    ):
        result.remove('restore-checkpoint-deadline')
    image = 'document_worker_repair_test.dart'
    if all(has_test(passed, image, name) for name in (
        'autonomous owner repair completes the original processing request exactly once',
        'real owned isolate processes and independently verifies image result',
        'timeout: owner-approved automatic retry verifies result and preserves original/identity',
        'crash: owner-approved automatic retry verifies result and preserves original/identity',
        'unsettled owned worker is quarantined; no duplicate until actual exit',
        'cross-school and pause cannot authorize a retained image retry',
        'invalid media is not retried and failed recovery never reports Healthy',
        'lost admission survives restart without replaying a private input or granting success',
        'borrowed output with another source fingerprint cannot become verified',
        'school change during an admitted repair prevents its late success from committing',
        'coalesced processing returns one worker and retains protected source',
    )):
        result.add('restart-owned-image-worker')
    if has_test(passed, owner, 'refresh-sync-view: real owner projection repair preserves queue and denies stale scope'):
        result.add('refresh-sync-view')
    return result
