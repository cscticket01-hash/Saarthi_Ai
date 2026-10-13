import 'universal_health.dart';

/// Reviewed local scheduling recovery. A verified timer is not a cloud ACK.
HealthProvider ownerTimerProvider({
  required String id,
  required bool Function(HealthContext) sameScope,
  required bool Function() expected,
  required bool Function() running,
  required void Function(HealthContext) restart,
  required DateTime Function() now,
  String playbook = 'restore-owner-timer',
  HealthObservation Function()? observation,
}) => HealthProvider(
  id: id,
  version: '2.0',
  check: (scope) async {
    if (!sameScope(scope)) return const HealthObservation(HealthState.unknown);
    if(observation!=null)return observation();
    if (!expected()) return const HealthObservation(HealthState.paused);
    return running()
        ? HealthObservation(HealthState.healthy, verifiedAt: now())
        : const HealthObservation(
            HealthState.degraded,
            failure: HealthFailure.worker,
          );
  },
  playbooks: [
    RecoveryPlaybook(
      id: playbook,
      kind: RecoveryKind.statelessWorker,
      failures: {HealthFailure.worker},
      precondition: (lease) async =>
          lease.valid && sameScope(lease.context) && expected() && !running(),
      execute: (lease) async {
        lease.check();
        if (!sameScope(lease.context) || !expected())
          throw StateError('Owner paused or school changed');
        restart(lease.context);
        lease.check();
      },
      verify: (lease) async =>
          lease.valid && sameScope(lease.context) && expected() && running(),
    ),
  ],
);
