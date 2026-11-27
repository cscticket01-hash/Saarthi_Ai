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
