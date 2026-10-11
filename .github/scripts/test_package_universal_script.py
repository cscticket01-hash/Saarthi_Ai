import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from package_universal_script import package


class UniversalPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.managed = self.root / 'school-backend/managed'
        self.managed.mkdir(parents=True)
        self.source = ("const VS_SETUP_SCHOOL_ID = '';\n"
                       "const VS_SETUP_CREATE_NEW_STORAGE = false;\n"
                       "const health={scriptBundleVersion:'2026-10-11.1'};\n")
        (self.managed / 'SaarthiManagedAll.gs').write_text(self.source)
        (self.managed / 'appsscript.json').write_text('{"runtimeVersion":"V8"}')

    def tearDown(self):
        self.temp.cleanup()

    def test_unchanged_generic_source_and_deterministic_package(self):
        first, second = self.root / 'first.zip', self.root / 'second.zip'
        proof = package(self.root, first, 'synthetic-commit')
        package(self.root, second, 'synthetic-commit')
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(set(archive.namelist()), {'Code.gs', 'appsscript.json', 'configuration.json', 'provenance.json', 'README.txt'})
            self.assertEqual(archive.read('Code.gs'), self.source.encode())
            config = json.loads(archive.read('configuration.json'))
            self.assertIsNone(config['schoolId']['value'])
            self.assertFalse(config['upgrade']['runSetup'])
            self.assertEqual(proof['sourceSha256'], hashlib.sha256(self.source.encode()).hexdigest())
            self.assertFalse(proof['configurationPropertyMarkersPresent'])
            self.assertIn(b'BLOCKED', archive.read('README.txt'))
            self.assertFalse(proof['schoolIdentityBoundByPackage'])

    def test_bound_creation_enabled_or_duplicate_marker_rejected(self):
        for source in (self.source.replace("= '';", "= 'vs-synthetic';"),
                       self.source.replace('= false;', '= true;'),
                       self.source + "const VS_SETUP_SCHOOL_ID = '';\n"):
            with self.subTest(source=source):
                (self.managed / 'SaarthiManagedAll.gs').write_text(source)
                with self.assertRaises(ValueError):
                    package(self.root, self.root / 'bad.zip')
                self.assertFalse((self.root / 'bad.zip').exists())

    def test_property_markers_are_not_reported_as_contract_acceptance(self):
        text = self.source + ''.join(f"p.getProperty('{key}');\n" for key in (
            'VS_SETUP_SCHOOL_ID', 'VS_SETUP_CREATE_NEW_STORAGE', 'VS_MANAGED_CENTRAL_ENDPOINT'))
        (self.managed / 'SaarthiManagedAll.gs').write_text(text)
        proof = package(self.root, self.root / 'configured.zip')
        self.assertTrue(proof['configurationPropertyMarkersPresent'])
        self.assertEqual(proof['configurationContractAcceptance'], 'UNVERIFIED')
        self.assertEqual(proof['status'], 'PACKAGED_ONLY_NOT_DEPLOYED')

    def test_actual_canonical_is_copied_without_school_binding(self):
        root = Path(__file__).resolve().parents[2]
        target = self.root / 'canonical.zip'
        package(root, target)
        with zipfile.ZipFile(target) as archive:
            self.assertEqual(archive.read('Code.gs'), (root / 'school-backend/managed/SaarthiManagedAll.gs').read_bytes())
            self.assertIsNone(json.loads(archive.read('configuration.json'))['schoolId']['value'])


if __name__ == '__main__':
    unittest.main()
