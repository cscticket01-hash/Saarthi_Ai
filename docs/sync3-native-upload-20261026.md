# Native resumable upload continuation

This PR adds a negotiated, opt-in native Google Drive resumable upload path to the existing durable Windows upload owner. It is not deployed or live-accepted.

## Contract
- New broker `brokerUploadResumableVersion:1` and Script `uploadResumableVersion:1` are both required. The Script advertises support only when its owner sets Script Property `VS_NATIVE_RESUMABLE_UPLOAD` to `1` after verifying Drive REST access. Existing scopes already include Drive and external requests; no extra OAuth scope is added.
- Files below roughly 512 KiB, missing stable upload keys, old brokers/Scripts, and opt-out deployments retain the existing verified full-upload path. A failed negotiated upload never silently switches to another writer.
- Each signed chunk binds school, original durable upload key, name, MIME, full hash and length. 512 KiB chunks include their own SHA-256. Provider sessions and OAuth tokens never leave the school Script.
- The Script allocates and persists one Drive file ID before initialization, queries provider status before sending bytes, and reuses the identity across expiry/restart. Interrupted or uncertain responses are left to the existing owner retry budget. Completion requires current parent/marker/size/MIME and full-content hash verification, not an offset or a notification.
- Native Google document types are refused. Existing files are never overwritten, trashed, moved or made public. A hash/key collision stops for review.
- Up to 64 incomplete sessions are retained per school. Completed journals are removed only after verification; the Drive marker provides durable duplicate protection. Unfinished sessions are not silently evicted or treated as committed. Capacity exhaustion requires owner review.

## Evidence and limits
Node provider-contract tests cover interrupted chunks, lost final ACK, restart, expired sessions, original file identity, corruption, wrong-school journals, unsafe provider URLs and opt-in gating. Broker tests cover school auth, bounds and receipt validation. Dart tests cover owner continuation, exact hashes, invalid completion and no-progress bounds.

These are simulated provider responses, not successful uploads to Google. Live TEST requires an authorized TEST entitlement, a matching isolated broker and Script bundle `2026-10-26.2`, verified Drive API access and owner opt-in. No actual school Script/configuration was changed.

The TEST readiness workflow now rejects a deployed runtime SHA or Script version different from the checked-out source; healthy old runtimes cannot certify new code.

Still pending: authorized TEST entitlement renewal, isolated matching deployment, real Drive upload/quota/latency acceptance, shared foreground/background dashboard-cache ownership, and physical Windows/Android/Web tests. No new background dashboard writer or second sync scheduler is introduced. Keep PR #135 DRAFT; no production rollout is authorized by this checkpoint.
