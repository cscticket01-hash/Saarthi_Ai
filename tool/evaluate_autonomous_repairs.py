"""Evaluate every catalog ID against implemented, closed owner capabilities.

No message-keyword inference grants execution. Eligibility below requires the
actual typed owner witness; entries not explicitly supported remain unavailable.
"""
import argparse
import csv
import json
import subprocess
from repair_test_evidence import passed_tests, verified_actions
from pathlib import Path
from build_health_knowledge import validate, CATALOG

ROOT = Path(__file__).resolve().parents[1]
CAPABILITIES = {
 'refresh-sync-view': ('lib/health/windows_health_adapter.dart','test/universal_health_test.dart','Windows; derived display only'),
 'restart-monitor-timer': ('lib/health/health_runtime.dart','test/universal_health_test.dart','Windows/Android; heartbeat only'),
 'restore-owner-timer': ('lib/health/owner_timer_provider.dart','test/universal_health_test.dart','Expected missing reconciliation/report timer'),
 'restore-admitted-dispatch': ('lib/windows_sync_engine.dart','test/autonomous_infrastructure_repair_test.dart','Captured owner deadline, enabled, idle, same school/profile; never new retry admission'),
 'restore-checkpoint-deadline': ('lib/windows_sync_engine.dart','test/autonomous_infrastructure_repair_test.dart','Existing future verified-checkpoint anchor; no checkpoint write'),
 'restore-health-delivery': ('lib/health/health_reporter.dart','test/autonomous_infrastructure_repair_test.dart','Diagnostic-only retry due; no active send/auth latch; persisted scope budget'),
 'restore-context-observer': ('lib/health/mobile_health_adapter.dart','test/autonomous_infrastructure_repair_test.dart','Android foreground, started, bound school/person; observation timer only'),
 'restart-owned-image-worker': ('lib/health/document_worker_owner.dart','test/document_worker_repair_test.dart','Typed exit/timeout of fixed pure image code, actual exit, retained private input, one retry, valid lease'),
}
DIRECT = {
 'sh-sync-view-worker': 'refresh-sync-view',
 'sh-monitor-worker-worker': 'restart-monitor-timer',
 'sh-sync-scheduler-worker': 'restore-owner-timer',
 'sh-health-report-timer-worker': 'restore-owner-timer',
 'sh-documents-timeout': 'restart-owned-image-worker',
 'sh-documents-unknown': 'restart-owned-image-worker',
}
SYNC = {'sh-smart-sync-networkpath','sh-smart-sync-timeout','sh-smart-sync-server','sh-smart-sync-quota'}
FIELDS = ['error_id','component','repair_solution','automatic_eligibility','actual_playbook_or_owner_capability','required_root_cause_evidence','verification_status','verification_test','reason_if_unsafe_or_unavailable']
AUDIT_FIELDS = ['source_file', 'source_error', 'root_cause_status', 'execution_permissions', 'preconditions', 'timeout_seconds', 'cooldown_seconds', 'attempt_limit', 'containment_policy']
FIELDS += AUDIT_FIELDS


def evaluate(data, verified=False, evidence=None):
    if verified and evidence is None:
        raise ValueError('Verified coverage requires per-test machine evidence')
    actions = verified_actions(evidence) if verified else set()
    sync_verified = verified and 'restore-admitted-dispatch' in actions
    validate(data)
    for key,(source,test,_) in CAPABILITIES.items():
        if not (ROOT/source).is_file() or not (ROOT/test).is_file():
            raise ValueError('Capability source/test missing: '+key)
        if key not in (ROOT/source).read_text():
            # Owner methods use a registered ID defined in the platform adapter.
            if key not in (ROOT/'lib/health/windows_health_adapter.dart').read_text() and key not in (ROOT/'lib/health/mobile_health_adapter.dart').read_text():
                raise ValueError('Capability has no actual source registration: '+key)
    rows=[]
    for rule in data['rules']:
        row=dict(zip(FIELDS[:9],[rule['id'],rule['component'],rule['solution'],'not automatic','',
            'Catalog signature/constant guard only; production root cause unconfirmed',
            'No executable repair verification',','.join(rule['testEvidence']),
            'No scope-bound, owner-approved repair interface for this exact case; retain originals and request owner evidence']))
        case = rule.get('sourceCase')
        row.update(source_file=(case['path'] + ':' + str(case['line'])) if case else ','.join(rule['source']),
            source_error=case['literal'] if case else json.dumps(rule['signature'], sort_keys=True),
            root_cause_status='Hypothesis only; exact source guard checked, runtime owner evidence still required',
            execution_permissions='None; catalog/learned history cannot authorize execution',
            preconditions='; '.join(rule['preconditions']), timeout_seconds=0,
            cooldown_seconds=0, attempt_limit=0,
            containment_policy='Preserve originals/queues; escalate to the owner; no speculative execution')
        if rule['id'] in DIRECT:
            key=DIRECT[rule['id']];source,test,witness=CAPABILITIES[key]
            row.update(automatic_eligibility='conditional infrastructure recovery',actual_playbook_or_owner_capability=key,
                required_root_cause_evidence=witness,verification_test=test,
                verification_status='Dedicated synthetic repair/guard suite PASS; no original-school claim' if key in actions else 'Executable fixture defined; exact-source owner fault proof pending',
                reason_if_unsafe_or_unavailable='Block without this owner witness, lease, durable audit or independent result; no business ACK implied')
            row.update(execution_permissions='Registered owner playbook only; same-school/profile lease and durable guardian admission',
                preconditions=witness, timeout_seconds=30 if key=='restart-owned-image-worker' else 5, cooldown_seconds=300 if key=='restart-owned-image-worker' else 60,
                attempt_limit=2, containment_policy='Unsettled result stays quarantined; no queue mutation or fabricated ACK. Original retained.')
            if key=='restart-owned-image-worker':
                row['repair_solution']='Kill only the application-owned pure image isolate and prove exit, then restart fixed processing once using private retained input. Verify container/dimensions/source identity. Resume the original processing request only if still pending; otherwise repair only its derived cache for a later owner request. Never claim an upload. Invalid input/PDF/native processing remains manual.'
        elif rule['id'] in SYNC:
            row.update(automatic_eligibility='Smart Sync owner-mediated recovery only',
                actual_playbook_or_owner_capability='Existing Smart Sync retry/receipt protocol; restore-admitted-dispatch only if its captured timer is missing',
                required_root_cause_evidence='Sync owner typed recoverable category, durable identity, quota/backoff and current scope. Guardian observes or restores an already-admitted dispatch; it never admits a business retry.',
                verification_status='Owner policy/identity/queue regressions and dispatch fault suite PASS; live cause unconfirmed' if sync_verified else 'Existing owner fixtures plus dispatch fault suite; final CI gate pending',
                verification_test='test/sync_recovery_policy_test.dart,test/windows_sync_durable_admission_test.dart,test/autonomous_infrastructure_repair_test.dart',
                reason_if_unsafe_or_unavailable='A scheduled retry is not repaired connectivity, a verified cloud revision or ACK; block if owner busy/paused/review/quota does not admit it')
        elif rule['level']=='C':
            row['reason_if_unsafe_or_unavailable']='Unsafe to infer a repair from this guard; identity/authorization/integrity/business intent or unknown cause requires verified owner/operator evidence. No executor registered.'
        rows.append(row)
    if len(rows)!=1000 or len({r['error_id'] for r in rows})!=1000:raise ValueError('Coverage must evaluate all 1000 individually')
    return rows


def write(rows,path):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('w',newline='') as file:
        writer=csv.DictWriter(file,fieldnames=FIELDS,lineterminator='\n');writer.writeheader();writer.writerows(rows)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--verified',action='store_true');parser.add_argument('--output',default='docs/self-healing-autonomous-coverage.csv');parser.add_argument('--evidence-log');args=parser.parse_args()
    if args.verified:
        if not args.evidence_log or not (ROOT/args.evidence_log).is_file():raise SystemExit('Verified report requires actual dedicated-test log')
        try: evidence=passed_tests((ROOT/args.evidence_log).read_text(), subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip())
        except ValueError as error: raise SystemExit(str(error))
    else: evidence=None
    data=json.loads(CATALOG.read_text());rows=evaluate(data,args.verified,evidence);write(rows,ROOT/args.output)
    totals={'evaluated':len(rows),'directInfrastructurePatterns':len(DIRECT),'smartSyncOwnerPatterns':len(SYNC),
            'automaticConditionalUnion':len(DIRECT)+len(SYNC),'uniqueExecutablePlaybooks':len(CAPABILITIES),
            'newExecutablePlaybooks':5,'manualOrUnavailable':len(rows)-len(DIRECT)-len(SYNC),
            'verifiedCatalogCases':sum('PASS' in r['verification_status'] for r in rows),
            'verifiedExecutableActions':len(verified_actions(evidence)) if evidence is not None else 0,
            'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            'verification':'Per-test machine evidence; synthetic only' if args.verified else 'awaiting exact-source CI'}
    print(json.dumps(totals))
