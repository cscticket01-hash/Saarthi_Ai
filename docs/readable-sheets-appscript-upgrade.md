# Corrected Google Sheets Apps Script

Latest user choice supersedes the earlier JSON default: text/records stay in readable Google Sheets, while photos/PDFs remain original-format Drive files with their URLs in the same Sheet record. Self-Healing remains removed. Based on PR #51 head `9881eca7ed76fbc8ee6d747ba1afdd0c97390ba9`.

Use the **whole** generated `school-backend/managed/SaarthiManagedAll.gs` bundle, version `2026-10-14.3`. The uploaded legacy-only script has add_student/add_teacher actions but lacks the signed managed_records/managed_upload/managed_health protocol required by current managed Windows clients. Do not paste only the adapter or edit generated fragments.

Default managed record storage is now Google Sheets. Explicit existing JSON storage remains available only for compatibility: deployments that already have JSON heads continue using JSON so new edits cannot be silently replaced by stale Sheets. An explicit switch to Sheets after JSON cutover is rejected and requires a reviewed migration. No existing Sheet, JSON generation, media or queue is deleted.

Student readable columns retain the existing 14-column format and Photo URL. Other categories expose Record ID plus their saved application fields, including photoUrl/pdfUrl/fileUrl when present. Canonical revisioned rows remain authoritative; the readable display is a verified projection. New fields add columns and older rows backfill in bounded reads. Owner-owned columns, very large display fields or more than 128 application fields block the derived view rather than overwriting cells; canonical records and ACKs remain intact.

Windows save hooks already notify Sync Engine 3.0 after durable local commit. The default scheduling delay is 250 ms; repeated changes coalesce and an active sync queues another pass. The engine still respects pause, automatic-sync setting, identity/license checks, network availability, retry deadlines and quotas. No second uploader or Self-Healing engine is introduced. Upload completion takes actual network/Google time; a local save is never represented as a verified cloud ACK.

## Existing deployment upgrade

1. Preserve the existing project and Script Properties, including VS_MANAGED_SCHOOL_ID, VS_MANAGED_ROOT_ID and VS_MANAGED_SECRET, and the existing deployment /exec URL.
2. Replace the managed source with the whole corrected bundle, preserving the manifest/scopes from the repository. Update the existing deployment to a new version.
3. Do not rerun setup, create a new empty school root, regenerate secrets, change school bindings or clear queues.
4. If the project contains **only legacy VS_FIREBASE_PROJECT_ID/VS_DRIVE_ROOT_ID settings** and lacks managed school/root/secret properties, stop before deployment: its original school/root and existing records must be identified and safely connected/imported first. This bundle cannot invent the correct managed school binding. The original readable legacy workbooks are retained; unmanaged legacy-format rows are not silently claimed as already migrated.
5. After publication approval, verify signed storage/check and a synthetic own-school record/photo readback, then test a real Windows save. No production deployment or original-school writes occurred during these tests.

This corrects API compatibility and the selected Sheet storage behavior in source. It does not prove which code, project properties or deployment URL the user's live school currently runs.
