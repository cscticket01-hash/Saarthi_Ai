"""Validate and compile declarative health knowledge; no executable actions."""
import json
from pathlib import Path
import sys
import re

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'lib/health/knowledge/catalog.v1.json'
OUTPUT = ROOT / 'lib/health/knowledge/catalog_data.dart'
CAPABILITIES = {
    ('sync-view', 'refresh-sync-view'),
    ('monitor-worker', 'restart-monitor-timer'),
    ('sync-scheduler', 'restore-owner-timer'),
    ('health-report-timer', 'restore-owner-timer'),
}
FIELDS = {'id', 'component', 'name', 'signature', 'symptoms', 'evidence',
          'possibleCauses', 'verifiedCause', 'severity', 'dataLossRisk',
          'dependencies', 'diagnostic', 'solution', 'level', 'playbook',
          'preconditions', 'timeoutSeconds', 'cooldownSeconds', 'attemptLimit',
          'verification', 'escalation', 'source', 'testEvidence', 'reviewedSource',
          'evidenceType'}


def validate(data, root=ROOT):
    if data.get('schema') != 1 or data.get('version') != '2.1.0':
        raise ValueError('Unsupported knowledge schema/version')
    if data.get('target') != 1000 or not isinstance(data.get('rules'), list) or not 0 < len(data['rules']) <= 1000:
        raise ValueError('Invalid catalog budget/target')
    ids, signatures = set(), set()
    failures = {'offline', 'timeout', 'server', 'quota', 'authorization', 'identity',
                'configuration', 'conflict', 'databaseLocked', 'storage', 'corrupt',
                'worker', 'decoding', 'rendering', 'overloaded', 'unknown'}
    owner_categories = {'', 'networkPath', 'timeout', 'server', 'quota',
                        'authorization', 'configuration', 'conflict', 'validation',
                        'fileMissing', 'unknown'}
    for rule in data['rules']:
        if set(rule) != FIELDS:
            raise ValueError('Missing or unrecognized rule fields')
        for field in ('id', 'component', 'name', 'severity', 'dataLossRisk', 'diagnostic',
                      'solution', 'level', 'playbook', 'verification', 'escalation',
                      'reviewedSource', 'evidenceType'):
            if not isinstance(rule[field], str) or len(rule[field]) > 2000:
                raise ValueError('Invalid or oversized text field')
        for field in ('symptoms', 'evidence', 'possibleCauses', 'dependencies',
                      'preconditions', 'source', 'testEvidence'):
            if not isinstance(rule[field], list) or len(rule[field]) > 32 or any(not isinstance(v, str) or len(v) > 2000 for v in rule[field]):
                raise ValueError('Invalid bounded evidence list')
        if not isinstance(rule['signature'], dict) or set(rule['signature']) != {'component', 'failure', 'ownerCategory'}:
            raise ValueError('Invalid typed signature schema')
        for field in ('timeoutSeconds', 'cooldownSeconds', 'attemptLimit'):
            if type(rule[field]) is not int:
                raise ValueError('Invalid numeric admission field')
        signature = tuple(rule['signature'][key] for key in ('component', 'failure', 'ownerCategory'))
        if not re.fullmatch(r'[a-z][a-z0-9_.-]{0,47}', rule['id']) or signature[1] not in failures or signature[2] not in owner_categories:
            raise ValueError('Invalid ID or unreachable typed signature')
        if rule['id'] in ids or signature in signatures:
            raise ValueError('Duplicate ID/signature or contradictory rule')
        ids.add(rule['id']); signatures.add(signature)
        if signature[0] != rule['component'] or signature[1] in {'none', 'unknown'} and rule['level'] == 'A':
            raise ValueError('Unreachable or unsafe rule')
        if rule['level'] not in {'A', 'B', 'C'}:
            raise ValueError('Invalid level')
        if rule['level'] == 'A':
            if (rule['component'], rule['playbook']) not in CAPABILITIES or signature[1] != 'worker':
                raise ValueError('Unauthorized automatic capability')
            if not 0 < rule['timeoutSeconds'] <= 30 or not 0 < rule['attemptLimit'] <= 3 or rule['cooldownSeconds'] < 60:
                raise ValueError('Unbounded automatic recovery')
        elif rule['playbook'] or rule['timeoutSeconds'] or rule['attemptLimit']:
            raise ValueError('Guidance cannot grant executable authority')
        for field in ('solution', 'verification', 'diagnostic', 'escalation', 'preconditions', 'symptoms', 'evidence', 'possibleCauses'):
            if not rule[field]:
                raise ValueError('Missing diagnostic/recovery evidence')
        if rule['verifiedCause'] is not None:
            raise ValueError('This seed catalog establishes hypotheses only')
        if rule['evidenceType'] != 'source-backed; synthetic matching':
            raise ValueError('Unsubstantiated production evidence')
        for path in [*rule['source'], *rule['testEvidence']]:
            if path.startswith('/') or '..' in Path(path).parts or not (root / path).is_file():
                raise ValueError('Broken or unsafe source/test reference')
    return len(ids)


def compile_catalog(data):
    payload = json.dumps(data, ensure_ascii=True, separators=(',', ':'))
    if "'''" in payload:
        raise ValueError('Unsupported literal delimiter in declarative data')
    return '// Generated by tool/build_health_knowledge.py; do not edit.\nconst healthKnowledgeJson = r\'\'\'' + payload + "''' ;\n"


if __name__ == '__main__':
    data = json.loads(CATALOG.read_text())
    count = validate(data)
    expected = compile_catalog(data)
    if '--check' in sys.argv:
        if not OUTPUT.exists() or OUTPUT.read_text() != expected:
            raise SystemExit('Generated knowledge differs from reviewed JSON')
    else:
        OUTPUT.write_text(expected)
    counts = {level: sum(r['level'] == level for r in data['rules']) for level in 'ABC'}
    print(json.dumps({'validated': count, 'target': 1000, 'levels': counts, 'missing': 1000-count}))
