"""Prepare existing reviewed engine for owner-authorized isolated TEST deployment.
Does not call Google APIs, run migration, or change repository source files.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil

SCHOOL = "vs-db8afb01a3be46a983c8284714d06e5d"
TEST_URL = "https://saarthi-sync-v2-test.onrender.com/school-cloud"
source = Path("school-backend/managed/SaarthiManagedAll.gs")
original = source.read_text(encoding="utf-8")
replacements = {
    "const VS_SETUP_SCHOOL_ID = '';": f"const VS_SETUP_SCHOOL_ID = '{SCHOOL}';",
    "const VS_SETUP_CREATE_NEW_STORAGE = false;": "const VS_SETUP_CREATE_NEW_STORAGE = true;",
    "UrlFetchApp.fetch('https://saarthi-oauth-staging.onrender.com/school-cloud'":
        f"UrlFetchApp.fetch('{TEST_URL}'",
}
prepared = original
for old, new in replacements.items():
    if prepared.count(old) != 1:
        raise SystemExit("Reviewed TEST preparation marker changed; owner bundle not generated.")
    prepared = prepared.replace(old, new, 1)
if original != source.read_text(encoding="utf-8"):
    raise SystemExit("Source changed during TEST preparation.")
target = Path("build/isolated-test-script")
target.mkdir(parents=True, exist_ok=True)
(target / "Code.gs").write_text(prepared, encoding="utf-8")
shutil.copyfile("school-backend/managed/appsscript.json", target / "appsscript.json")
(target / "preparation-evidence.json").write_text(json.dumps({
    "status": "PREPARED_ONLY_NOT_EXECUTED",
    "schoolId": SCHOOL,
    "testBackend": TEST_URL,
    "commit": os.environ.get("GITHUB_SHA", "local"),
    "sourceSha256": hashlib.sha256(original.encode()).hexdigest(),
    "preparedSha256": hashlib.sha256(prepared.encode()).hexdigest(),
    "exactConfigurationReplacements": len(replacements),
    "productionSourceChanged": False,
    "migrationExecuted": False,
}, indent=2), encoding="utf-8")
(target / "README.txt").write_text(
    "OWNER AUTHORIZATION REQUIRED. Only TEST Sync V2. Never install into an existing real-school project.\n"
    "Reuse a verified existing TEST project if present; otherwise create a separate TEST project.\n"
    "Paste Code.gs and appsscript.json. Run VS_prepareSchoolStorage with Google owner consent.\n"
    "This initial TEST copy permits a new school-marked root; no existing school storage is imported.\n"
    "After preparation, set VS_SETUP_CREATE_NEW_STORAGE back to false and save.\n"
    "Deploy this TEST project as Web app: Execute as yourself; Anyone. Signed ticket verification remains mandatory.\n"
    "Provide only its /exec URL, never connection secrets, tokens or passwords.\n"
    "Do not execute migration before authenticated TEST storage readiness succeeds.\n",
    encoding="utf-8",
)
print("Verified three TEST-only configuration replacements; owner bundle prepared, not deployed.")
