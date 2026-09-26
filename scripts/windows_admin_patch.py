VIDYA SAARTHI WINDOWS ADMIN - SETUP

1. Copy the folders/files from this pack into the ROOT of your GitHub repository.
   - lib/main_windows.dart
   - lib/windows_html_shim.dart
   - lib/windows_mobile_scanner_shim.dart
   - scripts/windows_admin_patch.py
   - .github/workflows/build-windows.yml

2. Do NOT replace lib/main.dart or lib/main_dashboard_screen.dart.
   Your existing Web/Android source stays unchanged.

3. Commit and push to main.

4. GitHub -> Actions -> Build Vidya Saarthi Windows Admin -> Run workflow.

5. When completed, download artifact:
   Vidya-Saarthi-Windows-<version>
   It contains:
   - Vidya_Saarthi_Setup_<version>.exe
   - Vidya_Saarthi_Windows_Portable_<version>.zip

WINDOWS UPDATE CONFIG (optional now; required when publishing updates)
Firestore collection: app_config
Document: windows_update
Fields:
  enabled: true
  latestVersion: "1.0.1"
  minimumVersion: "1.0.0"
  downloadUrl: "DIRECT_HTTPS_URL_TO_NEW_SETUP_EXE"
  forceUpdate: false
  releaseNotes: "What changed in this version"

Notes:
- The Windows app uses an Admin-only login entry.
- Existing Website build workflow is not replaced.
- The Windows build generates its platform folder only inside GitHub Actions.
- Current Windows stage is online-first. Offline database/sync is the next stage after this build passes.
