# Liquid Glass native appearance (2026-11-19)

The developer portal's **first** Glass card remains the stable `midnight-glass` preset ID for backwards compatibility. Its display name and live-painted tile are now **Liquid Glass**. Website draft/HEX/RGB/preview/navigation and explicit **Save Theme** remain unchanged. The same `functions/windows-theme.js` allowlist and revision-checked publication are used; no save happens when a card is merely selected.

Windows receives a translucent palette and local gradient backdrop only when the server-published `midnight-glass` ID is actually applied at the verified App Lock password boundary. Locked/offline devices keep their prior stored theme until their own verified unlock. No school record, licence, Cloudflare sync, Drive delivery or operational outbox is involved in this presentation change.

Android currently uses Liquid Glass as its **native default** (local palette, translucent navigation/cards, and blurred dashboard panels); the developer website continues to control Windows themes only. This does not add a new school-theme subscription to Android.

The provided HabitFlow/PrettySites reference supplies visual direction only (frosted cards, atmospheric movement, luminous edges). Its habit data, localStorage, account labels, remote video URL and unrelated application logic were **not** copied into Vidya Saarthi. The Flutter background is rendered on-device and works without network access. Reduced-motion users get a static backdrop.

Validation: Flutter appearance/widget tests should be run in CI on this branch. Inspect real Windows and Android screens for blur performance, contrast and App Lock changes before merging or producing a release.
