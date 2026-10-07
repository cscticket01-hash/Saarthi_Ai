# Windows 2.1.102 / Android 1.0.495 TEST

TEST artifacts only. No production deployment is performed. TEST-COMMIT.txt identifies the Windows source; both CI artifacts use the same workflow commit.

## Deployment boundary

The reported broker 2 / Script unknown mismatch cannot be repaired by an app update alone. Pending operations remain durable. The reviewed Script is protocol 2, storage version 1, bundle 2026-10-07.1. The existing broker must also support mobile_document (included in the reviewed branch). Live deployment requires separate approval and owner access. An /exec URL grants no editor access.

For an approved test environment, update the EXISTING Script deployment to the reviewed generated SaarthiManagedAll.gs, retain Script Properties (School ID, root, secret) and use Manage deployments → Edit → New version. Keep its /exec URL. Do not create new school storage, rerun startEmpty or replace root/secret. Keep the supplied scopes: Drive, spreadsheets, external request. Confirm signed storage/check reports brokerRecordSyncVersion 2, recordSyncVersion 2 and scriptBundleVersion 2026-10-07.1.

The adapter backfills old records into School Data / Vidya Saarthi School Data, one tab per collection. Original records_* JSON files remain intact. Each row holds identity, revision, deletion, operation ID, display label and inert canonical JSON fragments. Large backfills pause after 100 newly copied records per request, retain progress and resume on retries. A conflicting/foreign/duplicate source stops migration for review. New binary uploads go under Files / Photos or Files / Documents; backups under Backups. Existing referenced files retain their IDs/locations.

Tombstones prevent resurrection, including create-only backup restore. Only an exclusively referenced, exact document-revision immutable upload may be trashed after the tombstone is durable. Shared/unkeyed legacy files are retained safely; their physical cleanup remains operator review. No broad Drive delete occurs.

## Real-device acceptance (not established by CI)

1. Windows Settings → Local Data → Select/Change Folder: real native Select Folder opens. Cancel keeps current path/data. Choose an empty non-nested folder; existing verified migration copies and rebases data before activation, preserving the old copy. Existing student document picker is unchanged.
2. Publish a test notice offline. Restart; pending remains. Reconnect to approved compatible test backend/Script, Sync Now: only acknowledged operations reach Pending 0 and last-success timestamp. Android receives the exact notice once. Delete it while Android is offline; after refresh it disappears.
3. Select/publish a student ID on Windows. Sync. Matching Android Documents → Open my ID card gets the exact published PDF/hash/version. Open again offline from cache. Publish a new version, sync, refresh Android and verify new bytes replace the old version. Delete the document, refresh Android and verify the cached entry is unavailable, including after restart.
4. Repeat with PC-2 in the same school in both directions; stale edits must conflict rather than overwrite. Retry interrupted uploads/deletes without duplicates. Repeat with School B; no records/files/deletion may cross tenants.
5. Android header: brand/name, three-dot menu, no internal ID or refresh icon. Settings → About shows installed 1.0.495-review/build495 and What's New. App Update → Check for Updates really checks public releases; Report app problem and Sign out remain.

This Android artifact is debug-signed, not the live APK signing key. Test on a separate device/profile; it may not install over the release-signed live app. Do not uninstall a working live app just to force installation or discard its cached data.
