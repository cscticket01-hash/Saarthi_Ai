import copy
import json
import unittest
from build_health_knowledge import CATALOG, validate


class CatalogValidationTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(CATALOG.read_text())

    def test_reviewed_catalog(self):
        self.assertEqual(validate(self.data), 26)

    def test_duplicate_and_contradictory_signature(self):
        duplicate = copy.deepcopy(self.data['rules'][0])
        duplicate['id'] = 'different-id'
        self.data['rules'].append(duplicate)
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
