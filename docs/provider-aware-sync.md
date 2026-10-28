# Provider-aware sync admission

The existing sync owner and durable outboxes remain authoritative. Cloudflare transfer diagnostics now live inside the Sync & Backup Control Center and reads go through WindowsSyncEngine, with a shared 30-second minimum read interval and quota cooldown. Verified healthy/complete status disappears from the UI; unresolved transfer work and failures remain visible. No queue entry, conflict, history or delivery receipt is deleted to achieve visual cleanup.

The broker applies separate Google and Cloudflare school-scoped admission gates after actual quota failures. Google HTTP 429 and structured Script quota failures remain quota failures. Cloudflare HTTP 429 is handled before JSON parsing, including HTML/non-JSON error pages. Provider Retry-After seconds or HTTP dates establish a bounded minimum wait. After cooldown expiry, only one recovery probe is admitted on this instance. Repeated failures increase the cooldown; a later successful response clears its gate, while an older concurrent success cannot clear a newer failure. No hidden write replay occurs inside this layer.

Firestore SDK resource exhaustion is normalized to FIREBASE_QUOTA_EXCEEDED, and closes the current broker instance's project-wide Firebase admission gate for at least 15 minutes. Google quota failures do not close the Firebase gate. Permission failures and version conflicts retain their original semantics.

The HTTP broker returns bounded retryAfterMs and Retry-After on quota errors. Windows recovery preserves the provider minimum wait. Android attendance preserves original operation identity, persists its next attempt deadline after the response, and waits at least 60 seconds on quota failures. Server attendance delivery persists the upstream minimum deadline in the existing durable row. Verified ACKs, explicit deletes and review requirements remain unchanged.

## Boundaries

This is reactive backpressure, not an account-wide remaining-quota meter or a promise to stay within free plans. Broker gates are bounded, in-memory, per process; they do not coordinate multiple replicas or survive restart. Durable client/server queue deadlines do survive restart through their existing stores. Google gates use school identity because the executing Google account is not available as a verified broker scope; schools sharing a Script owner can still share that owner's limits. Cloudflare gates are also school-scoped and do not represent account-wide Workers capacity. Firebase gate scope is the configured central project on this instance.

Provider daily reset times and remaining allowance are not guessed. Exhausted daily quota, billing restrictions, credentials, storage exhaustion and conflicts can still require owner action. Existing measured Drive storage quota reporting remains opt-in. Global provider telemetry, coordinated admission across replicas, aggregate budgets for shared Google owners, and live Windows/web/Android acceptance need separate verified inputs and testing. No paid capacity, billing, deployment URL, school root or Google Script bundle is changed by this patch.

## Verification

Backend regression suite: 622 tests passed before the final single-probe admission change; the final targeted provider, attendance and HTTP handler suite passed 39 tests. Dart syntax parsing passed for the edited client files before the final authorization-precedence-only adjustment. Flutter dependency setup was blocked by automatic approval review after an unexpected instance-metadata request; full Flutter analysis/widget/device tests remain unverified. No production rollout was performed.


The subsequent local hardening and current verification are documented in `sync3-efficiency-hardening.md`; its shared-journal and configured-owner behavior supersede the earlier local-only scope notes above when explicitly enabled.
