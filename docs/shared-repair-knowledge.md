# Shared Sync repair knowledge — protocol 1

School records, files, names, device credentials, operation/record IDs and raw error messages never enter shared telemetry. Each licensed managed school may submit only the fixed module/category/outcome enum triplets. The broker derives a private salted school source hash for bounded deduplication and rate limiting; other schools receive neither that hash nor per-school diagnostics. Reports remain untrusted and cannot publish or authenticate a fix.

Developer-only APIs:

- `developer/managed/repair-knowledge/status`: current publication and sanitized pattern counters.
- `developer/managed/repair-knowledge/publish`: `{publication:{expectedSequence,policy:{enabled,rules},evidenceId}}`.
- `managed/repair-knowledge/pull`: existing authenticated, licensed, device-checked school route; returns the same signed global envelope plus its ordinary authenticated school wrapper.

Publishing enabled rules requires a protected Admin-SDK-written `repair_knowledge_evidence/<sha256-id>` row with `protocol:1`, `suite:'shared-repair-policy-v1'`, `passed:true`, `policyHash` from `functions/repair-knowledge.js`, the reviewed 40-hex `sourceCommit`, integer `verifiedAt` and `expiresAt` (maximum seven days). This proof must be produced after the candidate policy and its targeted regression tests pass in trusted CI, not from client-reported success counters. Browser Firestore clients, including the developer wildcard, cannot write proof, signing state or private source state. The signing private key stays on the broker. Operator approval publishes through the API with a compare-and-set sequence. A disabled empty policy is a privilege-reducing emergency kill switch and does not require success evidence. Rollback to a prior rule set requires a newly signed higher sequence and matching, unexpired evidence.

Only bounded existing handlers are configurable: retry floor (5–900 seconds, never below provider Retry-After), unchanged-conflict probe cooldown (300–3600 seconds), ID-card probe cooldown (120–3600 seconds, existing attempt budget intact), and batch cap (2–10, never above local adaptive admission). Rules select fixed modules/categories and deterministic 1–100% cohorts. They cannot execute code, access school data, acknowledge writes, clear queues, overwrite conflicts or change licences/authentication.

The client verifies the pinned Ed25519 key, protocol, purpose, signature, timestamp/24-hour lease, monotonic sequence, equal-sequence payload hash and every action/parameter before saving and applying. Cached expiry returns handlers to their compiled defaults while retaining the local sequence high-water mark. The broker renews a publication with a higher sequence only while its test evidence remains valid; withdrawn or expired evidence produces a newer disabled policy. Background refresh is at most hourly and does not block a business sync. Offline devices retain valid cached rules only until expiry; immediate offline revocation is not promised.

## Initial activation

1. Provision a dedicated Ed25519 signing key and independent random telemetry salt in the broker secrets: `SAARTHI_REPAIR_KNOWLEDGE_ENABLED=true`, `SAARTHI_REPAIR_KNOWLEDGE_PRIVATE_KEY`, `SAARTHI_REPAIR_KNOWLEDGE_KEY_ID=repair-20261029-v1`, `SAARTHI_REPAIR_KNOWLEDGE_REPORT_SALT` (at least 32 characters). Do not reuse OAuth, Drive or device signing keys.
2. The Windows release workflow pins the public verification key `QTxk98cwRGkVvFTfeqRRwdTnKy_-9cr4dbZQJrSAz1g` with key ID `repair-20261029-v1`. Only the public key is committed. Optional repository variables `SAARTHI_REPAIR_KNOWLEDGE_PUBLIC_KEY` (raw 32-byte unpadded base64url) and `SAARTHI_REPAIR_KNOWLEDGE_KEY_ID` override this release pin together when deliberately rotating it. Builds outside that workflow must supply their own matching defines; without a pin the receiver stays off.
3. Release/install that receiver once, run isolated two-school tests, and publish a tested canary rule with protected evidence. Broader rollout requires observing the result; counter reports alone are not approval.
4. Subsequent supported rule changes arrive remotely without another installer. New native functionality, new repair action types, database changes or key-pin replacement still require an app release.

This implementation does not claim production activation, real-school throughput, measured speed gains, or automatic resolution of every sync error.


## Permanent local repair-pattern memory (v2 snapshots)

Each school profile keeps two separate local views in its existing durable
`_windows_sync_status/recovery` record:

- **Short-lived evidence:** at most 100 scoped per-operation observations. A
  verified-resolved display entry expires after 24 hours; unresolved evidence
  and the original durable outbox/receipts are never cleared by this cleanup.
- **Durable pattern catalog:** at most 1,000 compact
  `collection/category/allowlistedFailureCode` patterns with first/last seen
  timestamps, recurring observations, and verified resolution counts. **No
  automatic age-based deletion**. When storage reaches the 1,000-pattern bound,
  the oldest unverified pattern is evicted before a verified one. All fields
  are checked during restore; version-1 local snapshots are upgraded without
  resetting queues. Application upgrades and ordinary restarts reuse the
  same school-isolated local store.

Patterns are observations, not executable recipes. A `verified` event must
match an existing school-scoped pending operation before a new verified repair
is counted. Repeated success messages for the same operation do not increase
the count. An unresolved conflict, generic request success, or expired cache
never grants a cloud ACK, changes payment amounts, or authorizes overwrites.

The already existing `WindowsLearnedSyncRules` stores allowed deterministic
actions independently of display events and seeds missing **safe** rules from
previously verified pattern evidence after restart. This does **not** add
unrestricted new repair actions.

### Sharing to other schools

At most once per hour when the shared-repair service is configured, the
Windows client submits **only recently observed patterns** reduced to
`module/category/outcome` enums by `sharedRepairObservations`. No
school/record/operation IDs, error text, personal details, payment values, or
credentials enter this payload. The broker aggregates untrusted, bounded
category observations across licensed schools. A school cannot retrieve
another school's records or source hash.

An observed solution in School A **does not automatically become executable
code in School B**. Cross-school action changes continue to require an
already-supported bounded handler, verified CI evidence, developer approval,
a signed policy and rollout checks. The Windows client validates the policy
before applying it; unsigned/unconfigured policy falls back to local compiled
behavior. This distinction is necessary to prevent one compromised device
from pushing unsafe financial repairs to all schools.

This change does not modify the school-owned Apps Script, transfer business
data to the learning service, activate missing production signing secrets,
or replace real-device and school-cloud acceptance tests.


## Server-authoritative permanence, clean installation and cross-school rollout

The central broker now archives every published, cryptographically signed repair
policy at the protected, server-only Firestore path
`repair_knowledge/version-<sequence>`, separately from the current
`repair_knowledge/published` head. Every renewal and evidence-expiry kill switch
gets a new immutable sequence. The publication archive is not stored in school
Drive or dependent on a particular PC; uninstall, in-app reset and Windows
reinstallation cannot erase the server records. Deleting the central backend
itself, provider retention changes or administrative deletion are separate
disaster-recovery risks; include this collection in central backups.

The 24-hour Windows "Smart Repair History" is only a recent, school-scoped UI
view. The existing local v2 pattern catalog and signed remote-policy cache are
non-authoritative *copies* used to avoid repeated offline diagnostics. The
canonical, device-independent approved policy lives on the broker. Fresh app
installs and older compatible clients pull the current signed rules from the
same school-authenticated endpoint when online. A client release is still
required for a new native repair algorithm or signing-key rotation. No raw
student names, fee amounts, Drive URLs, operation IDs or school IDs leave a
school in the shared observation payload.

Untrusted school observations do not grant publication authority. A reviewed
repair only reaches another school after the server has independently
verified the fix, obtained protected CI evidence, the developer has approved
a compatible policy, and the signed rollout has passed. This avoids remote
code execution or cross-school data leakage.

## Staged Windows 24-hour online authorization policy

The managed-school Windows client has a new opt-in build control:
`--dart-define=SAARTHI_WINDOWS_REQUIRE_DAILY_ONLINE=true`. With that policy
enabled, the existing authenticated server `managed/session` proof gives at
most 24 hours of offline **interactive** access, subject to the *shorter*
licence or signed device-lease expiry. At the deadline the already-mounted
dashboard remains visible but becomes read-only: an explicit "Internet
unavailable, please connect internet" notice appears; pointer and keyboard
interaction and manual/automatic Sync Engine admission stop, without
deleting any local business records, outbox items or media. Pressing
"Verify online" attempts the same authenticated school verification; a
successful fresh proof resumes normal interaction.

Existing production Windows builds intentionally keep their current
offline behavior until the guarded rollout is enabled and tested. This
read-only UI barrier does not constitute tamper-proof DRM. Managed broker
authorization/licence/device checks are still the server-side authority;
a modified client may bypass local UI restrictions, so financial and data
operations must always be authenticated/authorized on the server. New
installations without an existing verified school identity cannot claim a
24-hour offline grant. Genuine blocked/expired licence states remain
separately denied, not mistaken for an internet outage.

24 hours is a *verification interval*, not a guarantee of constant network
availability. If the network is unavailable after that interval, normal
business interaction remains locked until verification succeeds. Physical
Windows rollback/clock-change, power-loss, multi-PC, printer, account lock,
backup/restore, and device-revocation tests must pass before release.


### Device-lease compatibility for daily read-only mode

The currently enforced Windows device authorization token has a **15-minute**
signed offline lifetime, independent of the old 72-hour licence cache. A
client-side 24-hour UI check alone cannot lengthen this token. The server-side
`createManagedDeviceAccess` now supports either its existing 15-minute
default or an explicitly configured 24-hour signed window; the Windows Ed25519
verifier permits the longer lifetime **only** in the daily-online build.
The TEST broker exposes `SAARTHI_TEST_DAILY_ONLINE_WINDOW=true` solely when
isolated TEST mode and signed device enforcement are both active. The server
still re-checks device registry, membership and school entitlement on **every**
actual online request. Offline revocation cannot be instantaneous; widening
the signed offline window may increase exposure to a revoked device, which
requires a documented production security decision.

A production 24-hour enforcement rollout needs a corresponding vetted server
device-lease configuration, production signing-key/pin verification and
physical 24-hour expiration/recovery tests. A new client paired to the old
15-minute server lease will still lose device authorization at 15 minutes;
that must not be mislabeled as successful 24-hour acceptance.
