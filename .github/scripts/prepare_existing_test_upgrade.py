"""Prepare a non-destructive upgrade for the already-bound isolated TEST project.

No Google API calls, school binding, setup execution or storage creation.
"""
import hashlib
import json
import os
from pathlib import Path

SCHOOL = "vs-db8afb01a3be46a983c8284714d06e5d"
TEST_URL = "https://saarthi-sync-v2-test.onrender.com/school-cloud"


def prepare(source):
    replacements = {
        "const VS_SETUP_SCHOOL_ID = '';": f"const VS_SETUP_SCHOOL_ID = '{SCHOOL}';",
        "UrlFetchApp.fetch('https://saarthi-oauth-staging.onrender.com/school-cloud'":
            f"UrlFetchApp.fetch('{TEST_URL}'",
    }
    if source.count("const VS_SETUP_CREATE_NEW_STORAGE = false;") != 1:
        raise ValueError("Storage creation must remain disabled.")
    for old, new in replacements.items():
        if source.count(old) != 1:
            raise ValueError("Canonical TEST configuration marker changed.")
        source = source.replace(old, new, 1)
    return source


def main():
    source_path = Path("school-backend/managed/SaarthiManagedAll.gs")
    source = source_path.read_text(encoding="utf-8")
    prepared = prepare(source)
    target = Path("build/existing-test-upgrade")
    target.mkdir(parents=True, exist_ok=True)
    (target / "Code.gs").write_text(prepared, encoding="utf-8")
    (target / "appsscript.json").write_bytes(
        Path("school-backend/managed/appsscript.json").read_bytes())
    (target / "provenance.json").write_text(json.dumps({
        "status": "PREPARED_ONLY_NOT_DEPLOYED", "schoolId": SCHOOL,
        "backend": TEST_URL, "sourceCommit": os.environ.get("GITHUB_SHA", "local"),
        "sourceSha256": hashlib.sha256(source.encode()).hexdigest(),
        "preparedSha256": hashlib.sha256(prepared.encode()).hexdigest(),
        "createNewStorage": False, "configurationReplacements": 2,
        "setupExecuted": False, "recordsChanged": False,
    }, indent=2), encoding="utf-8")
    (target / "README.txt").write_text(
        "UPGRADE ONLY: reuse the existing, owner-verified TEST Sync V2 Apps Script project.\n"
        "First verify its bound school and Drive root match the existing TEST service.\n"
        "Preserve script properties, deployment identity and existing Sheets/Drive storage.\n"
        "Update source and existing deployment version only after owner authorization.\n"
        "Do not run VS_prepareSchoolStorage, create storage, rebind, migrate or purge.\n"
        "Read signed health after deployment and require reviewed bundle2026-10-11.1.\n"
        "Keep import/device rollout disabled until their separate acceptance gates pass.\n",
        encoding="utf-8")
    print("Existing TEST upgrade prepared; storage creation disabled; no deployment performed.")


if __name__ == "__main__":
    main()
