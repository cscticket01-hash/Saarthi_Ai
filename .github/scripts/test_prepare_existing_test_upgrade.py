import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("upgrade", Path(__file__).with_name("prepare_existing_test_upgrade.py"))
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)


class ExistingUpgradeTest(unittest.TestCase):
    def setUp(self):
        self.source = Path("school-backend/managed/SaarthiManagedAll.gs").read_text(encoding="utf-8")

    def test_actual_bundle_preserves_storage_and_only_changes_binding_configuration(self):
        result = upgrade.prepare(self.source)
        self.assertIn("const VS_SETUP_CREATE_NEW_STORAGE = false;", result)
        self.assertNotIn("const VS_SETUP_CREATE_NEW_STORAGE = true;", result)
        restored = result.replace(f"const VS_SETUP_SCHOOL_ID = '{upgrade.SCHOOL}';", "const VS_SETUP_SCHOOL_ID = '';", 1)
        restored = restored.replace(f"const VS_MANAGED_CENTRAL_DEFAULT = '{upgrade.TEST_URL}'", "const VS_MANAGED_CENTRAL_DEFAULT = 'https://saarthi-oauth-staging.onrender.com/school-cloud'", 1)
        self.assertEqual(restored, self.source)

    def test_creation_enabled_source_rejected(self):
        with self.assertRaises(ValueError):
            upgrade.prepare(self.source.replace("const VS_SETUP_CREATE_NEW_STORAGE = false;", "const VS_SETUP_CREATE_NEW_STORAGE = true;"))

    def test_duplicate_configuration_rejected(self):
        with self.assertRaises(ValueError):
            upgrade.prepare(self.source + "\nconst VS_SETUP_SCHOOL_ID = '';\n")

    def test_already_bound_or_changed_endpoint_rejected(self):
        for source in [self.source.replace("const VS_SETUP_SCHOOL_ID = '';", "const VS_SETUP_SCHOOL_ID = 'foreign';"), self.source.replace("https://saarthi-oauth-staging.onrender.com/school-cloud", "https://foreign.invalid/school-cloud")]:
            with self.assertRaises(ValueError):
                upgrade.prepare(source)


if __name__ == "__main__":
    unittest.main()
