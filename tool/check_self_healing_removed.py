"""Check retired engine deletion without inspecting or modifying school data."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
retired=['lib/health','functions/universal-health-telemetry.js','.github/workflows/universal-health-review.yml']
for path in retired:
    # An empty directory is harmless; no engine file may remain in it.
    p=root/path
    assert not p.is_file() and not (p.is_dir() and any(f.is_file() for f in p.rglob('*'))),path
pattern=re.compile(r'UniversalHealth|HealthRuntime|HealthObservation|HealthProvider|HealthContext|HealthReporter|RecoveryPlaybook|WindowsHealthAdapter|MobileHealthAdapter|MobileHealthLifetime|WindowsHealingMonitor|DeveloperHealthView|DocumentWorkerOwner|(?:import|export)\s+[\'"][^\'"]*health/')
for p in (root/'lib').rglob('*.dart'):
    assert not pattern.search(p.read_text()),str(p.relative_to(root))
backend=(root/'functions/managed-schools.js').read_text()
for reference in ['createHealthTelemetry','healthTelemetry','mobile_health_report','managed/health/report','developer/managed/health/summary']:
    assert reference not in backend,reference
# Storage probes and owner Sync code must remain; "health" alone does not mean
# the retired automatic engine and must not accidentally erase these checks.
for p in ['lib/windows_sync_engine.dart','lib/windows_pending_school_sync.dart','lib/windows_local_storage.dart','lib/mobile/school_session.dart']:
    assert (root/p).is_file(),p
assert "managed/storage/check" in backend
assert 'DocumentImageWorker.instance.process' in (root/'lib/document_pipeline.dart').read_text()
print('Retired engine, startup hooks, UI integrations and telemetry handlers absent; independent Sync/storage/document owners retained.')
