# PR consolidation and platform audit — 11 October 2026

Reviewed baseline: PR26 source `2cc37e9b3567027c10b6a7ab27eae030e8c31374`, remote refs already fetched by the coordinator. No PR closure, branch deletion, main merge, release, or cloud mutation performed.

## Consolidation

PR24 commits missing from PR26 ancestry: `f6100a1` and `afd5308`; both documentation/evidence updates. Coordinator owns their reconciliation. Runtime fixes are preserved in PR26 ancestry. Historical acceptance evidence is not fresh application acceptance.

PR25 changed seven files. Its verifier, decoder smoke, and synthetic benchmark implementations are preserved in PR26; `verify_pdf.py` additionally accepts exhaustive disjoint declared non-QR page geometry and its tests cover that contract. PR26 adds actual-application renderer verification. The separate preparation workflow and two historical reports do not require restoring older tool implementations. Keep PR25 open until the coordinator's evidence-based decision; do not delete it.

PR20's twenty-file patch is reconciled semantically, not blindly merged:

| PR20 files | Current preserved implementation |
|---|---|
| `.github/workflows/platform-review.yml` | Expanded exact-source multi-platform workflow; coordinator owns integration |
| `functions/managed-schools.js` | Notification device binding, post-ACK hints, signed broker diagnostics and school scope preserved and expanded |
| `functions/test/central-handler.test.js`, `staging-school-cloud/server.cjs` | Safe status/categories and strict TEST bootstrap fence expanded |
| `functions/test/managed-schools.test.js`, `functions/test/managed-storage.test.js` | Existing notification, multilingual signed request and storage tests retained with newer coverage |
| `lib/main_android.dart`, `test/android_startup_test.dart` | UI starts before optional notification setup; token registration, lifecycle refresh and new status listener retained |
| `lib/mobile/school_messaging.dart`, `lib/mobile/school_notifications.dart` | Central messaging validation, scoped notice/sync hints and content-free invalidation retained |
| `lib/mobile/school_session.dart`, `test/mobile_smart_sync_test.dart` | Coalesced signal follow-up refresh, durable verified cache, transport classification and renewal retained; newer timeout/cache failures tested |
| `lib/main_dashboard_screen_windows.dart` | Newer immediate durable scheduler path replaces older outgoing priority route |
| `lib/windows_backend_bridge.dart`, `test/windows_document_queue_test.dart` | UTF-8 JSON responses, durable document retention and newer pause/retry/ambiguous-response guards retained |
| `lib/windows_sync_engine.dart`, `test/windows_sync_revision_test.dart` | Version-aware priority queue, cached protocol, coalesced bounded dispatch and newer ACK-preservation tests retained |
| `school-backend/managed/SaarthiManagedAdapter.gs`, `SaarthiManagedAll.gs` | UTF-8 HMAC and signed storage handling retained in canonical newer bundle |
| `oauth-broker/test/central-staging.test.cjs` | Existing typed status/diagnostic handler expectations retained with expanded server fences |

No unique old implementation was selected for cherry-pick. This mapping supports preservation, not automatic closure of PR20.

## Confirmed accessible fixes

1. The verifier's native ZXing fallback previously ran inside the Python process without a hard per-call deadline. It now executes the unchanged raster in a disposable QR-only worker subprocess with a 15-second timeout. Only ZBar exit4 with empty output admits fallback. Wrong identities, multiple symbols, non-QR output and other errors still fail closed. Worker output is validated and exception text is not exposed. Cooperative benchmark budget and overall workflow deadline remain separate.
2. Website student activity used the Windows PC heartbeat as an additional admission condition. Fresh student reports were displayed as zero once the management PC stopped contacting the service, contradicting independent Android cloud operation. The aggregate now admits only bounded, non-future measured activity reports independently of PC heartbeat; blocked/disabled/archived schools remain excluded. The activity label describes recently seen or unknown/stale heartbeat evidence rather than inferring offline state.

## Verification and limits

- Python verifier unit tests: 27/27 PASS in this worktree.
- `git diff --check`: PASS.
- Real decoder smoke: UNVERIFIED; local `zbarimg` is unavailable. Direct native fallback worker fails closed without installed ZXing.
- New Flutter monitor regression requires SDK/hosted execution; no Flutter result fabricated.
- Android static review: atomic cache rollback and verified timestamp pairing, after-signal coalescing, generation checks, optional FCM setup and network/error distinctions remain present. No extra QR reader changes; AgentD owns those paths.
- Website static review: developer operations remain server-authenticated; live-view and monitoring identify selected school and distinguish client observations from server ACK evidence. Actual signed-in browser flows and release links are not asserted tested.
- Synthetic PDF verification is not physical card printing/scanning or actual school authorization acceptance.

Full platform and physical acceptance remain PARTIAL pending exact integrated-source CI and live/physical checks.
