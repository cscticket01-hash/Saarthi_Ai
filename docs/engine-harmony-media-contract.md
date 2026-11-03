# Vidya Saarthi: Sync 3 + TemplateForge 3 + Compression media contract

**Scope:** Additive changes stacked on PR #206; not a production Cloudflare
authority cutover. Keep the existing Windows local outbox, signed school Drive
owner, school isolation, and precise Drive acknowledgements. Do not create a
second sync engine, an external PDF API, or new school data stores.

## Existing user-facing PDF capabilities worth keeping

Only the school workflow features analogous to Acrobat/iLovePDF are relevant:
local multi-language OCR; A4/US-Legal image/PDF/Office import; deskew/orientation
and safe field/portrait/QR replacement; actual-size preview and print; school
signature/logo/seal; quality-aware photo compression; PDF delivery preflight.

General-purpose PDF merge/split, marketing watermarks, arbitrary redaction/
e-signing, cloud OCR subscriptions and unrelated office conversions are **not**
added. School files and identifiers must not leave the existing authorized
school account.

## Implemented integration in this branch

1. **One compression owner for template assets.** The normalized TemplateForge
   PNG is processed by `DocumentProcessingEngine.templateArtworkUpload` in an
   isolate. Try maximal lossless PNG compression; only adopt smaller bytes if
   every decoded RGBA pixel and dimensions match. If a colour profile is
   present, skip re-encoding. Keep the immutable source hash; derive the
   immutable published content hash from the bytes actually uploaded. Verify
   the Drive read-back hash before publishing the school-scoped manifest.
   Existing versions, deletion markers and previous selections remain intact.
2. **Bounded, independent image preparation.** Photo, logo, seal and principal
   signature reuse the existing 40 KiB portrait/30 KiB branding compressors.
   A record prepares at most two independent file uploads concurrently. Each
   returns a verified school-bound Drive file reference; never publish partial
   record metadata, reuse a foreign-school response or invent a Drive file ID.
   Existing upload identities permit idempotent retries. Child business-record
   updates still use the one original serialized sync owner.
3. **Common PDF output preflight.** New ID cards, reference documents and
   imported rendered PDFs pass `SchoolMediaBudgets.verifyGeneratedPdf`. Detect
   missing PDF header or EOF and apply exact derived-document byte limits.
   Do not truncate, silently rasterize text/QR, or replace an oversized
   printable document with a degraded preview.

## Size semantics (binary KiB)

- Portrait photo: at most **40 KiB** when quality safeguards permit.
- School logo / principal signature / seal: at most **30 KiB**, preserve alpha.
- Generated ID: **85 KiB**. Report card / marksheet: **150 KiB**.
- Generated receipt / expense receipt: **30 KiB**.
- **Important:** The PDF byte ceilings are safety gates, not a general-purpose
  PDF rewriter. A complex PDF that cannot meet the limit safely is rejected
  and retained; never claim that every source can be compressed to the target.
  Imported template artwork is lossless, not arbitrarily forced under 30 KiB.

## ACK and device-state invariants

- A Cloudflare `cloudflareAccepted` receipt means temporarily durable edge
  staging, **not** a verified Google Drive file ID or canonical Sheet revision.
- A downstream person/document metadata record referencing a file must wait for
  the exact verified file receipt or a future signed, recoverable provisional
  reference protocol; no optimistic file URL guessing.
- The 24-hour Cloudflare temporary-data clock begins only **after verified**
  Drive ACK. Pending work and newer edits never expire by wall clock.
- Deleted, retired or restored entities require their existing generation and
  linked-child lifecycle; do not bypass with generic record CAS.
- An offline device must replay its retained local operation identity and
  compare exact school, generation and revision before cloud adoption.

## Required release gates (NOT certified by this branch)

- Run and pass all GitHub Windows, TemplateForge, compression, Sync 3 and
  Cloudflare tests at the final SHA; inspect failed jobs rather than hiding
  pending work.
- On a valid isolated TEST school with a compatible deployed Apps Script
  `/exec`, measure app save, Cloudflare receipt, peer visibility and exact
  Drive verification **separately**, including process kill and reconnect.
- Verify actual 1/2/5 distinct Windows PCs, Android person-scoped reads, A4
  and Legal 100%-scale printouts, 12+ rows, QR decode and old-photo rejection.
- Simulate simultaneous template changes and deletions on 2/5 PCs; server-side
  cloud CAS and physical multi-device validation remain necessary.
- Do not merge this stacked branch as a production feature or promote PR #206
  live-authority flags without these migration, lifecycle and remote gates.

## Non-goals

No direct Adobe API dependency; no new licences or paid PDF tools. No
background migration, no fake instant Drive ACK, no hidden deletion of saved
school originals, and no duplicated self-repair engine.
