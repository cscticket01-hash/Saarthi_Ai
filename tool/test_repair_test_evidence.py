import json
import unittest
from repair_test_evidence import REQUIRED_SUITES, passed_tests, verified_actions


def fixture():
    events = [{'type': 'repairEvidence', 'sourceCommit': 'a' * 40}]
    for index, path in enumerate(sorted(REQUIRED_SUITES)):
        events.extend([
            {'type': 'suite', 'suite': {'id': index, 'path': '/test/' + path}},
            {'type': 'testStart', 'test': {'id': index, 'suiteID': index, 'name': 'unrelated success'}},
            {'type': 'testDone', 'testID': index, 'result': 'success', 'skipped': False, 'hidden': False},
        ])
    events.append({'type': 'done', 'success': True})
    return events


def encode(events):
    return '\n'.join(json.dumps(e) for e in events)


class EvidenceTests(unittest.TestCase):
    def test_success_banner_is_not_repair_evidence(self):
        with self.assertRaises(ValueError):
            passed_tests('All tests passed!')

    def test_complete_unrelated_suites_do_not_grant_action_proof(self):
        self.assertEqual(verified_actions(passed_tests(encode(fixture()))), set())

    def test_failed_case_is_rejected_even_with_a_successful_final_marker(self):
        events = fixture()
        events[3]['result'] = 'failure'
        with self.assertRaises(ValueError): passed_tests(encode(events))

    def test_skipped_case_cannot_be_verified(self):
        events = fixture()
        events[3]['skipped'] = True
        with self.assertRaises(ValueError): passed_tests(encode(events))

    def test_incomplete_case_cannot_be_verified(self):
        events = fixture()
        del events[3]
        with self.assertRaises(ValueError): passed_tests(encode(events))

    def test_missing_owner_suite_cannot_borrow_other_test_success(self):
        events = fixture()
        events = events[:1] + events[4:]
        with self.assertRaises(ValueError): passed_tests(encode(events))

    def test_duplicate_completion_cannot_inflate_success(self):
        events = fixture()
        events.insert(-1, events[3])
        with self.assertRaises(ValueError): passed_tests(encode(events))

    def test_old_source_log_cannot_verify_new_source(self):
        with self.assertRaises(ValueError): passed_tests(encode(fixture()), 'b' * 40)
        self.assertTrue(passed_tests(encode(fixture()), 'a' * 40))

    def test_verified_count_needs_specific_owner_fault_proof(self):
        passed = {('autonomous_infrastructure_repair_test.dart',
            'restart-monitor-timer: real heartbeat owner recovery and pause denial')}
        self.assertEqual(verified_actions(passed), {'restart-monitor-timer'})
        self.assertNotIn('refresh-sync-view', verified_actions(passed))

    def test_empty_completed_run_cannot_be_verified(self):
        with self.assertRaises(ValueError):
            passed_tests(encode([{'type': 'done', 'success': True}]))


if __name__ == '__main__': unittest.main()
