# Universal Apps Script packaging

The helper `.github/scripts/package_universal_script.py` creates a generic ZIP from the canonical `school-backend/managed/SaarthiManagedAll.gs` and Apps Script manifest. It copies both unchanged and includes owner configuration guidance and SHA256 provenance. It binds no school and performs no network request, deployment, setup, migration or storage creation.

Run from the repository root:

```sh
python .github/scripts/package_universal_script.py --source-commit REVIEWED_SOURCE_SHA
python -m unittest discover -s .github/scripts -p 'test_package_universal_script.py' -v
```

Default output is `build/universal-script/Vidya_Saarthi_Universal_AppsScript.zip`. Keep the identical ZIP for all schools. The configuration manifest contains no assigned school ID, credential or signing key. Its endpoint choices are the existing trusted production and isolated TEST broker URLs, not arbitrary URLs.

The canonical source must independently implement owner-set Script Properties `VS_SETUP_SCHOOL_ID`, `VS_SETUP_CREATE_NEW_STORAGE` and `VS_MANAGED_CENTRAL_ENDPOINT`, preserving existing school/root/secret bindings and rejecting endpoint injection and redirect exposure. Packaging detects marker presence only; it explicitly leaves configuration-contract acceptance UNVERIFIED. Missing markers produce a BLOCKED notice. Source behavior and real deployed identity require independent tests and signed health evidence.

For an existing deployment, preserve all Script Properties and the deployment identity; update source/version only. Do not execute setup, rebind, create new storage, run migrations or change records as part of an upgrade. For a new school, setting the assigned identity and consenting to first storage setup are separate owner actions. Storage creation defaults false. The TEST endpoint must reject schools outside the isolated TEST identity.

This preparation is not evidence that the universal bundle has been deployed, controlled import/device enforcement enabled, or School A/B and five-PC acceptance passed. Shared Sync acceptance remains separately gated.
