# Cloudflare school delivery

Sync Engine 3 retains SQLite/local outboxes and the existing Drive revision,
ownership and financial validation rules. Cloudflare is a durable delivery
spool. A staging receipt never becomes a Drive file ID or record revision.

## Routing

Versioned record writes/deletes for every broker school collection except
Notices use a school-isolated FIFO spool when the client sends
`edgeDeliveryVersion: 1` and the broker enables admission. Teachers and staff
share the existing `teachers_directory` model; payroll settings and salaries
retain their existing collections. ID card/document files use the file spool
and their metadata follows only after a verified permanent Drive file ID.
Notices and attendance retain their existing dedicated Cloudflare lanes.
Reads remain verified Drive reads; this change does not add an unverified
Cloudflare overlay or alter Firebase login/licence/security authority.

File staging accepts at most the existing 20 MiB limit. Chunks are at most
512 KiB and hash verified; the complete immutable manifest is checked before
delivery. Drive upload offsets can resume inside a staging chunk. Staged
bytes are removed only after the verified committed Drive receipt; immutable
chunk hashes and operation receipts remain for replay protection.

Clients poll one authenticated, school-bound delivery ticket. A timeout keeps
the original local operation ID and queued work. Batch receipts retain each
successful/terminal acknowledgement, so a restart retries only unresolved
operations. CAS conflicts retain both versions for review. Transient errors
and quota refusals retain work and delay delivery.

## Rollout and rollback

Deploy the additive Worker before the updated broker. Preserve `EDGE_KEY`,
`LANES` namespace and migration tag v1. No new Durable Object class, namespace
reset or whole-school data copy is required.

The Render service environment is the admission source of truth:

- `SAARTHI_CF_ALL_DATA_ENABLED=true` enables opt-in admission.
- Existing `SAARTHI_CF_SYNC_SCHOOLS` still restricts eligible schools.
- Legacy callers without the new protocol retain verified direct delivery.

To stop new admission, set **only** `SAARTHI_CF_ALL_DATA_ENABLED=false` and
redeploy. Retain the new broker/Worker, key and original school scope until
all accepted jobs settle. Status and authenticated drain deliberately remain
available with admission disabled. Never delete a queued row or staged file
as an error-cleanup shortcut.

Before publishing opt-in clients, run the retained synthetic TEST-school
acceptance workflow with the exact deployed broker commit pinned in
`.github/acceptance/cloudflare-delivery-runtime.json` on the dedicated
`verify/cloudflare-delivery-live` branch. Its target school and endpoint are
fixed to the isolated TEST broker in source; it must not create, edit or delete
real-school fixtures. Its separate `vidya-saarthi-sync-test` Worker, key and
Durable Object namespace must never be substituted for the production key or
namespace. Use `wrangler.test.jsonc` for its source configuration.

This upgrade does not create provider quota, enable the optional shared quota
journal, certify production load, or certify physical devices. Provider
refusals, revocation and external Sheet edits can still require operator
attention; errors must remain visible until resolved.
