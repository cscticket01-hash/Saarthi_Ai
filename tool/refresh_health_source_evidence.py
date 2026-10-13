"""Refresh provenance only; preserve the existing 1000 IDs and message selection."""
import json
from build_health_knowledge import CATALOG,validate,compile_catalog,OUTPUT
from extend_health_knowledge import source_cases,make_rule

if __name__=='__main__':
    data=json.loads(CATALOG.read_text());old=[r['id'] for r in data['rules']]
    cases={(c['path'],c['kind'],c['literal']):c for c in source_cases()}
    for i,rule in enumerate(data['rules']):
        if 'sourceCase' not in rule:continue
        case=rule['sourceCase'];actual=cases.get((case['path'],case['kind'],case['literal']))
        if actual is None:raise SystemExit('Existing guard removed; review '+rule['id'])
        data['rules'][i]=make_rule(actual,rule)
    assert [r['id'] for r in data['rules']]==old
    validate(data);CATALOG.write_text(json.dumps(data,ensure_ascii=True,indent=2)+'\n');OUTPUT.write_text(compile_catalog(data))
    print('Preserved 1000 IDs; refreshed source lines/full-inventory ambiguity only')
