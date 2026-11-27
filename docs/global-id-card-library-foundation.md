# Global ID Card Library — phase 1

Developer-approved scope: website Global Features, Firebase Storage and Firestore, existing Render school broker, no Cloudflare changes. All current designs free; no payment processing or gateway credentials. Signature, PIN, address geometry and PR #438 are explicitly out of scope.

Implemented: private original PDF upload (8 MiB first-stage limit, fictional sample and artwork rights confirmation), checksum readback, category list, draft/archive/restore, server-only metadata, authenticated managed school catalog projection and version-scoped manual grant foundation. No direct client writes to global library, entitlement or purchase collections. Existing developer and school membership/licence guards reused. No download URLs or original source exposed to schools. Header/footer validation is only input screening; no parsing, extraction or automatic approval claimed.

Deployment prerequisite: verify exact existing Firebase bucket, private object IAM and no public bucket access or download tokens; set SAARTHI_GLOBAL_ID_CARD_BUCKET on the existing Render service only after authorized staging verification. No bucket or environment change in this PR. The bucket remains disabled by default. Isolated TEST broker has no global production bucket.

Remaining phases: safe central PDF parsing/rendering, OCR and semantic field detection, exact font and physical geometry detection, removal of sample text/photo/logo/signature/seal/QR, source-to-clean-artwork verification, human review when uncertain, immutable sanitized package and version publication/rollback. Then Windows registry refresh, verified school-scoped offline cache and preview/print/download/bulk integration, premium catalog previews and entitlement enforcement. Payment provider and checkout remain disabled; future verified provider receipts must be server-created, idempotent and school/version-bound. No school can use a draft. No publication route intentionally exists yet. A true permanent deletion/retention policy and failed-upload orphan reconciliation require review before activation.

Tests added to existing Node test suite, not manually run. No new workflow or deployment.
