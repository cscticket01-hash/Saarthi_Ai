"""The release must actually opt-in to hidden per-user Windows sync.

Static review runs before Inno is available. A release with an invisible
window runner but no startup registration is not background capable.
"""
from pathlib import Path
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / 'workflows/build-windows.yml'


class BackgroundInstallerTests(unittest.TestCase):
    def test_installer_has_per_user_optional_logon_start(self):
        source = WORKFLOW.read_text(encoding='utf-8')
        self.assertIn('Name: "backgroundsync"; Description:', source)
        self.assertIn('Flags: checkedonce', source)
        self.assertIn('Name: "{userstartup}\\Vidya Saarthi Background Sync"', source)
        self.assertIn('Parameters: "--saarthi-background"', source)
        self.assertIn('WorkingDir: "{app}"; Tasks: backgroundsync', source)

    def test_production_build_patches_single_native_instance(self):
        source = WORKFLOW.read_text(encoding='utf-8')
        self.assertLess(source.index('configure_windows_single_instance.py'),
                        source.index('Build Windows Admin App'))
        self.assertIn('test_windows_single_instance.py', source)
        self.assertIn('test_windows_background_installer.py', source)

    def test_script_does_not_install_privileged_system_service(self):
        source = WORKFLOW.read_text(encoding='utf-8')
        self.assertIn('PrivilegesRequired=lowest', source)
        self.assertNotIn('Name: "{commonstartup}\\Vidya Saarthi Background Sync"', source)


if __name__ == '__main__':
    unittest.main()
