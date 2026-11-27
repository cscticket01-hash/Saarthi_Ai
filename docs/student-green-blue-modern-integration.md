# Green Blue Modern student ID — staged, not active

The approved original Canva artwork is not yet uploaded. Existing catalog/default is unchanged to prevent a broken selectable template. Before registering, upload the exact cleaned 600 DPI PNG to `assets/student_green_blue_modern_front.png` (337769 bytes; SHA-256 `08912d18ce48222ac150f0b3bd3189270ad96534e7764d243d8456d8d243e2b9`). No sample student details are allowed in the artwork.

Then append this entry to assets/id_card_catalog.json, leaving other entries intact:

```json
{
  "id": "student-green-blue-modern-v1",
  "name": "Green Blue Modern • Front only",
  "manifest": "assets/student_green_blue_modern_manifest.json",
  "kinds": [
    "studentId"
  ],
  "frontAsset": "assets/student_green_blue_modern_front.png"
}
```

The renderer changes stage optional oval clipping, vertical text and confirmed student UID lookup. Without an activation and matching server assignment the entire UID area is blank. Existing geometry defaults remain unchanged.

Not verified: Flutter compile, actual Windows preview/PDF geometry, UID projection sync and production activation, QR decode, bulk printing, long text and artwork redistribution licence. Master PNG stays at 600 DPI; current PDF background optimization is 300 DPI. Do not merge/release until artwork and acceptance are complete.

## Full-resolution download follow-up

The existing WindowsPdfGenerationPolicy.generateOnRecordSave remains false. The student dashboard and native card preview now route the explicit Download action through renderLocalDownload. For the new template it preserves the original background bytes at full resolution and uses a lossless cropped image pipeline (existing 1600px safety bound remains). The local download uses the existing bounded 80 MiB local print envelope, not the 85 KiB sync/outbox limit; no cloud budget is changed. The new template's native preview hides the separate Print action so users can print the downloaded PDF. Actual student data now includes the stable generation for UID lookup. No tests, compile or real print acceptance were run. Artwork and catalog activation remain blocked until the original PNG is present. Front-only bulk and draft designer paths still require further integration.

## Catalog, front-only bulk and acceptance follow-up

Registered the new student-only catalog entry, gated on the exact approved 337769-byte PNG SHA-256. The original file has not yet reached GitHub; the gallery omits only this new entry until it does. Existing catalog items remain available. Existing tests now require the asset before merge. Selection validates manifest/artwork without PDF generation; all PCs must be updated before selection. Added front-only bulk A4 layout, lossless artwork and explicit Download action, preserved shape/rotation and new-template color in saved job fingerprints, shared background provider, existing byte budgets, and regression tests. Existing bulk rollout feature flag remains unchanged (off by default); do not bypass it without release review. Fixed school-wide layout cannot be applied from experimental custom designer; the bundled selection remains the supported route. Local PNG upload, compile, actual render/QR checks and release remain pending. Canva artwork redistribution permission is unverified. No manual workflow was launched.
