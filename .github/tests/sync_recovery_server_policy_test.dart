import '../../lib/sync_recovery_policy.dart';

void main() {
  var checks=0;
  void check(bool ok,String label) {
    if(!ok)throw StateError(label);
    checks++;
  }
  for(final status in [500,502,503,504,507,599]) {
    final decision=SyncRecoveryDecision.classify(status:status);
    check(decision.retry,'HTTP $status retains a transport retry');
    check(!decision.review,'HTTP $status is not a permanent review');
  }
  for(final status in [401,403,409]) {
    final decision=SyncRecoveryDecision.classify(status:status);
    check(!decision.retry,'HTTP $status must not auto retry');
    check(decision.review,'HTTP $status requires review');
  }
  for(final code in ['SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_STORAGE_NOT_PREPARED',
      'SCRIPT_IDENTITY_MISMATCH','OPERATION_ID_CONFLICT']) {
    final decision=SyncRecoveryDecision.classify(status:500,code:code);
    check(!decision.retry,'Explicit $code overrides generic HTTP 500');
  }
  final quota=SyncRecoveryDecision.classify(status:429);
  check(quota.retry && quota.kind==SyncFailureKind.quota,'quota waits safely');
  final unknown=SyncRecoveryDecision.classify();
  check(!unknown.retry,'unknown failure never authorizes retry');
  final capped=SyncRecoveryDecision.classify(status:503).delay(100,jitter:0.5);
  check(capped>Duration.zero && capped<=const Duration(minutes:10),'backoff bounded');
  print('PASS $checks recovery policy assertions');
}
