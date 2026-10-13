import copy
import json
import unittest
from evaluate_autonomous_repairs import evaluate,CAPABILITIES,DIRECT,SYNC
from build_health_knowledge import CATALOG

class AutonomousCoverageTests(unittest.TestCase):
    def test_every_id_evaluated_and_only_explicit_owner_witnesses_admit_recovery(self):
        data=json.loads(CATALOG.read_text());rows=evaluate(data)
        self.assertEqual(len(rows),1000)
        supported=[r for r in rows if r['automatic_eligibility']!='not automatic']
        self.assertEqual({r['error_id'] for r in supported},set(DIRECT)|SYNC)
        self.assertEqual(len(supported),10)
        self.assertEqual(len(CAPABILITIES),8)
        self.assertTrue(all('pending' in r['verification_status'] for r in supported))
        self.assertTrue(all(r['required_root_cause_evidence'] and r['reason_if_unsafe_or_unavailable'] for r in rows))
    def test_all_source_guard_unknowns_without_owner_interface_remain_manual(self):
        data=json.loads(CATALOG.read_text());rows={r['error_id']:r for r in evaluate(data)}
        for rule in data['rules']:
            if 'sourceCase' in rule:self.assertEqual(rows[rule['id']]['automatic_eligibility'],'not automatic')
    def test_catalog_text_cannot_register_a_playbook_or_grant_permissions(self):
        data=json.loads(CATALOG.read_text());rule=next(r for r in data['rules'] if 'sourceCase' in r)
        rule['solution']='execute arbitrary generated code and clear queue'
        with self.assertRaises(ValueError):evaluate(data)

if __name__=='__main__':unittest.main()
