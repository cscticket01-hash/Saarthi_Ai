"""Regression checks for the production Java and review Kotlin scaffolds."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / '.github/scripts/configure_school_messaging.py'
NAMESPACE = 'com.example.saarthi_ai'


class SchoolMessagingGeneratorTest(unittest.TestCase):
    def setup_project(self, root, language):
        app = root / 'android/app'
        (app / 'src/main').mkdir(parents=True)
        (app / 'build.gradle.kts').write_text(f'android {{ namespace = "{NAMESPACE}" }}\n')
        (app / 'src/main/AndroidManifest.xml').write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
            '<application android:name="${applicationName}">'
            '<activity android:name=".MainActivity" /></application></manifest>')
        source = app / f'src/main/{language}' / Path(*NAMESPACE.split('.'))
        source.mkdir(parents=True)
        filename = 'MainActivity.java' if language == 'java' else 'MainActivity.kt'
        (source / filename).write_text(
            f'package {NAMESPACE};\npublic class MainActivity extends FlutterActivity {{}}'
            if language == 'java' else
            f'package {NAMESPACE}\nclass MainActivity : FlutterActivity()')
        shutil.copytree(ROOT / '.github/android', root / '.github/android')
        return app

    def generate(self, root):
        subprocess.run([sys.executable, str(SCRIPT)], cwd=root, check=True, capture_output=True, text=True)

    def assert_single_activity(self, app):
        activities = list((app / 'src/main').rglob('MainActivity.*'))
        self.assertEqual(len(activities), 1)
        self.assertEqual(activities[0].suffix, '.kt')
        self.assertIn('school_messaging', activities[0].read_text())
        ET.parse(app / 'src/main/AndroidManifest.xml')

    def test_production_java_activity_is_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.setup_project(root, 'java')
            self.generate(root)
            self.assert_single_activity(app)

    def test_review_kotlin_activity_is_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.setup_project(root, 'kotlin')
            self.generate(root)
            self.assert_single_activity(app)

    def test_repeated_generation_preserves_one_activity_and_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.setup_project(root, 'java')
            self.generate(root)
            before = {str(p.relative_to(app)): p.read_bytes() for p in app.rglob('*') if p.is_file()}
            self.generate(root)
            after = {str(p.relative_to(app)): p.read_bytes() for p in app.rglob('*') if p.is_file()}
            self.assertEqual(before, after)
            self.assert_single_activity(app)


if __name__ == '__main__':
    unittest.main()
