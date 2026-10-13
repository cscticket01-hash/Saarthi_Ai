import copy
import json
import unittest
from build_health_knowledge import CATALOG, validate
from extend_health_knowledge import source_cases, make_rule
from pathlib import Path
import tempfile


class CatalogValidationTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(CATALOG.read_text())

    def test_reviewed_catalog(self):
        self.assertEqual(validate(self.data), 1000)

    def test_full_target_is_required(self):
        self.data['rules'].pop()
        with self.assertRaises(ValueError): validate(self.data)

    def test_context_cannot_gain_automatic_permission(self):
        rule = next(r for r in self.data['rules'] if 'sourceCase' in r)
        rule.update(level='A', playbook='restore-owner-timer', component='sync-scheduler')
        with self.assertRaises(ValueError): validate(self.data)

    def test_renamed_context_cannot_claim_another_source_guard(self):
        rule = next(r for r in self.data['rules'] if 'sourceCase' in r)
        rule['sourceCase']['literal'] = 'A made up error with no source guard'
        with self.assertRaises(ValueError): validate(self.data)

    def test_source_line_requires_review_after_movement(self):
        rule = next(r for r in self.data['rules'] if 'sourceCase' in r)
        rule['sourceCase']['line'] += 1
        with self.assertRaises(ValueError): validate(self.data)

    def test_same_id_cannot_change_failure_or_owner(self):
        rule = next(r for r in self.data['rules'] if 'sourceCase' in r)
        rule['signature']['failure'] = 'worker'
        with self.assertRaises(ValueError): validate(self.data)

    def test_case_schema_rejects_raw_metadata(self):
        rule = next(r for r in self.data['rules'] if 'sourceCase' in r)
        rule['sourceCase']['studentName'] = 'private student'
        with self.assertRaises(ValueError): validate(self.data)

    def test_comments_strings_and_dynamic_messages_are_not_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'lib').mkdir()
            (root / 'lib/owner.dart').write_text('''
// throw StateError('Comment is not a case');
/* throw StateError('Block comment is not a case'); */
final text = "throw StateError('Text is not a case')";
final template = `throw new Error('Template text is not a case')`;
throw StateError('User $privateName');
throw StateError('Prefix' + privateValue);
throw StateError('Prefix' 'Suffix');
throw StateError('Real constant guard');
throw StateError('Real constant guard');
throw const FormatException(
  'Actual multiline guard',
);
throw new Error('Actual backend guard');
''')
            cases = source_cases(root)
            self.assertEqual([c['literal'] for c in cases],
                             ['Real constant guard', 'Actual multiline guard', 'Actual backend guard'])
            self.assertTrue(all(c['origins'] == 1 for c in cases))

    def test_ambiguity_in_an_unselected_source_must_be_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'lib').mkdir()
            for name in ('id_card_first.dart', 'id_card_second.dart', 'windows_backup_integrity.dart'):
                (root / 'lib' / name).write_text("throw const FormatException('Same actual guard');")
            cases = source_cases(root)
            self.assertEqual(len(cases), 3)
            self.assertEqual([c['origins'] for c in cases], [3, 3, 3])

    def test_forged_unique_origin_count_is_rejected(self):
        rule = next(r for r in self.data['rules'] if r.get('sourceCase', {}).get('origins', 0) > 1)
        rule['sourceCase']['origins'] = 1
        with self.assertRaises(ValueError): validate(self.data)

    def test_all_contextual_solutions_are_deterministic_owner_guidance(self):
        cases = [r for r in self.data['rules'] if 'sourceCase' in r]
        self.assertEqual(len(cases), 974)
        self.assertEqual(len({r['name'] for r in cases}), 974)
        for rule in cases:
            self.assertEqual(rule, make_rule(rule['sourceCase'], rule))
            self.assertEqual((rule['playbook'], rule['attemptLimit'], rule['timeoutSeconds']), ('', 0, 0))

    def test_duplicate_and_contradictory_signature(self):
        duplicate = copy.deepcopy(self.data['rules'][0])
        duplicate['id'] = 'different-id'
        self.data['rules'][-1] = duplicate
        with self.assertRaises(ValueError): validate(self.data)

    def test_missing_solution(self):
        self.data['rules'][0]['solution'] = ''
        with self.assertRaises(ValueError): validate(self.data)

    def test_unsafe_permission_cannot_be_added(self):
        rule = self.data['rules'][0]
        rule.update(level='A', playbook='clear-queue', timeoutSeconds=5, cooldownSeconds=60, attemptLimit=2)
        with self.assertRaises(ValueError): validate(self.data)

    def test_unbounded_admission(self):
        rule = next(r for r in self.data['rules'] if r['level'] == 'A')
        rule['attemptLimit'] = 9999
        with self.assertRaises(ValueError): validate(self.data)

    def test_broken_source(self):
        self.data['rules'][0]['source'] = ['lib/not-real.dart']
        with self.assertRaises(ValueError): validate(self.data)

    def test_missing_verification(self):
        self.data['rules'][0]['verification'] = ''
        with self.assertRaises(ValueError): validate(self.data)

    def test_unreachable_owner_signal(self):
        self.data['rules'][0]['signature']['ownerCategory'] = 'raw exception text'
        with self.assertRaises(ValueError): validate(self.data)

    def test_malformed_solution_type(self):
        self.data['rules'][0]['solution'] = {'execute': 'shell'}
        with self.assertRaises(ValueError): validate(self.data)


if __name__ == '__main__': unittest.main()
