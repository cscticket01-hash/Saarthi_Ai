# Developer school credentials and full Windows appearance preview

School list → Action → Change School Password updates the existing Firebase Auth UID, verifies its managed school membership and revokes old refresh sessions. It never creates a replacement school, resets trial dates, modifies school records, changes Drive bindings or changes the local Windows App Lock. Passwords are not returned or included in audit records. Archived/disabled schools require their existing access controls to be resolved first. If revocation or acknowledgement fails after Auth accepts the update, retrying the same password is safe; success is not shown without complete confirmation.

Windows Theme offers five presets, saturation/value picking, hue, RGB integers, HEX, unsaved draft/reset, and explicit revision-checked Save. Preview never publishes a draft. School activation retains the existing all-registered-PC App Lock barrier.

The preview is a separate browser build of the actual Windows screen widgets, generated from the same source. A page selector and expanded view allow navigation through application screens and forms in both modes. The generated build alone substitutes native SQLite, credential storage, disk and recovery adapters; persistence is in RAM, cloud transport throws, sync initialization is disabled, and hosting CSP disallows external connections. Production Windows source and its sync owner are not rewritten. Parent/frame messages accept only validated RGB, mode and whitelisted pages from their matching same-origin window; no developer tokens or school records are passed.

Demo screens use synthetic records. The preview is for layout and colour inspection, not Windows printer, camera, native storage, licensing, OAuth or real-cloud acceptance. Native document rendering and full application checks remain separate. Browser checks capture 24 real application page variants in both modes and reject runtime errors or external requests.

The browser preview uses the existing bundled DejaVu fallback fonts for offline text; the installed Windows app retains Segoe UI. This is a colour/layout preview, not a claim of browser/native pixel-identical typography.
