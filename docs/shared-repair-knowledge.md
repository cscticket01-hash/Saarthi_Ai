# Shared Sync repair knowledge — protocol 1

School records, files, names, device credentials, operation/record IDs and raw error messages never enter shared telemetry. Each licensed managed school may submit only the fixed module/category/outcome enum triplets. The broker derives a private salted school source hash for bounded deduplication and rate limiting; other schools receive neither that hash nor per-school diagnostics. Reports remain untrusted and cannot publish or authenticate a fix.

Developer-only APIs:

- `developer/managed/repair-knowledge/status`: current publication and sanitized pattern counters.
- `developer/managed/repair-knowledge/publish`: `{publication:{expectedSequence,policy:{enabled,rules},evidenceId}}`.
- `managed/repair-knowledge/pull`: existing authenticated, licensed, device-checked school route; returns the same signed global envelope plus its ordinary authenticated school wrapper.

Publishing enabled rules requires a protected Admin-SDK-written `repair_knowledge_evidence/<sha256-id>` row with `protocol:1`, `suite:'shared-repair-policy-v1'`, `passed:true`, `policyHash` from `functions/repair-knowledge.js`, the reviewed 40-hex `sourceCommit`, integer `verifiedAt` and `expiresAt` (maximum seven days). This proof must be produced after the candidate policy and its targeted regression tests pass in trusted CI, not from client-reported success counters. Browser Firestore clients, including the developer wildcard, cannot write proof, signing state or private source state. The signing private key stays on the broker. Operator approval publishes through the API with a compare-and-set sequence. A disabled empty policy is a privilege-reducing emergency kill switch and does not require success evidence. Rollback to a prior rule set requires a newly signed higher sequence and matching, unexpired evidence.

Only bounded existing handlers are configurable: retry floor (5–900 seconds, never below provider Retry-After), unchanged-conflict probe cooldown (300–3600 seconds), ID-card probe cooldown (120–3600 seconds, existing attempt budget intact), and batch cap (2–10, never above local adaptive admission). Rules select fixed modules/categories and deterministic 1–100% cohorts. They cannot execute code, access school data, acknowledge writes, clear queues, overwrite conflicts or change licences/authentication.

The client verifies the pinned Ed25519 key, protocol, purpose, signature, timestamp/24-hour lease, monotonic sequence, equal-sequence payload hash and every action/parameter before saving and applying. Cached expiry returns handlers to their compiled defaults while retaining the local sequence high-water mark. The broker renews a publication with a higher sequence only while its test evidence remains valid; withdrawn or expired evidence produces a newer disabled policy. Background refresh is at most hourly and does not block a business sync. Offline devices retain valid cached rules only until expiry; immediate offline revocation is not promised.

## Initial activation (not performed by this PR)

1. Provision a dedicated Ed25519 signing key and independent random telemetry salt in the broker secrets: `SAARTHI_REPAIR_KNOWLEDGE_ENABLED=true`, `SAARTHI_REPAIR_KNOWLEDGE_PRIVATE_KEY`, `SAARTHI_REPAIR_KNOWLEDGE_KEY_ID=repair-v1`, `SAARTHI_REPAIR_KNOWLEDGE_REPORT_SALT` (at least 32 characters). Do not reuse OAuth, Drive or device signing keys.
2. Set release repository variables `SAARTHI_REPAIR_KNOWLEDGE_PUBLIC_KEY` to the raw 32-byte public key encoded as unpadded base64url and its matching key ID. The Windows release workflow passes these public values to the binary. Missing configuration leaves the feature off without interrupting current sync.
3. Release/install that receiver once, run isolated two-school tests, and publish a tested canary rule with protected evidence. Broader rollout requires observing the result; counter reports alone are not approval.
4. Subsequent supported rule changes arrive remotely without another installer. New native functionality, new repair action types, database changes or key-pin replacement still require an app release.

This implementation does not claim production activation, real-school throughput, measured speed gains, or automatic resolution of every sync error.
