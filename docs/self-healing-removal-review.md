# Self-Healing removal

The standalone Self-Healing engine has been removed from Windows, Android and the developer website. This branch is based on JSON storage PR #50 head `26a229cb266d1731fcd4f583a96ec19755e0636d`, preserving JSON migration and PR #49 document conflict work.

Removed: the complete `lib/health` source directory, 1,000-case catalog, monitor/dashboard widgets, startup/lifecycle adapters, observation wrappers, recovery providers/playbooks, history/reporter/telemetry clients, backend telemetry routes/module, dedicated engine tests, benchmarks, build tools, documentation and its review workflow. The developer Health Command Center action and Sync page Self-Healing entries are removed. Old standalone-engine TEST branch gates are retired.

Retained: Smart Sync 3.0, its retries/CAS/conflicts/verified cloud ACK/readback, school-isolated offline storage, pending queues, inventory, attendance, notices, licensing, QR, ID cards, JSON storage, independent local/Drive connection checks and manual owner review. Signed `managed_health` is the existing storage capability probe, not the removed Self-Healing engine; removing it would break school connection verification.

The document/image worker was extracted into `lib/document_image_worker.dart` with only its existing processing lifetime, resource limits, isolate settlement and output validation. All automatic restart/recovery/playbook/provider code was deleted. Document/PDF processing keeps source preservation and defensive byte copies. Document processing deduplication/cache uses the caller's explicit school/profile scope rather than the removed guardian context.

No local/Drive school files, sync queue entries or stored diagnostic history/report documents are deleted during upgrades. Persisted old history becomes unused; runtime code does not load or upload it. Removed legacy telemetry requests reject as unsupported rather than silently accepting them. Cloud storage probes remain functional.

Verification covers actual isolated image processing, no automatic restart on worker fault/timeout, retained source bytes, invalid result rejection, same-school deduplication, separate-school requests, bounded uncooperative workers, defensive pipeline cache copies, retired telemetry API rejection with no data writes, and retained storage probes. CI checks Windows/Linux retained owners and Windows/Android/Web builds through the existing platform review.

No merge, release or deployment has been performed. The installed/live version continues to contain Self-Healing until reviewed changes are published with explicit approval.
