import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
spec = importlib.util.spec_from_file_location('reuse', Path(__file__).with_name('reuse_sync3_capacity.py'))
reuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)

class ReuseCapacity(unittest.TestCase):
    def test_only_identical_fixture_inputs_reuse_verified_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True).strip()
            git('init', '-q'); git('config', 'user.email', 'fixture@example.invalid'); git('config', 'user.name', 'Fixture')
            (root/'functions').mkdir(); (root/'functions/input.js').write_text('original')
            git('add', '.'); git('commit', '-qm', 'baseline'); baseline = git('rev-parse', 'HEAD')
            (root/'readme.md').write_text('documentation only'); git('add', '.'); git('commit', '-qm', 'docs')
            self.assertTrue(reuse.unchanged(root, baseline, git('rev-parse', 'HEAD')))
            (root/'functions/input.js').write_text('changed'); git('add', '.'); git('commit', '-qm', 'runtime')
            self.assertFalse(reuse.unchanged(root, baseline, git('rev-parse', 'HEAD')))
            with self.assertRaises(subprocess.CalledProcessError):
                reuse.unchanged(root, 'missing-proof', git('rev-parse', 'HEAD'))

if __name__ == '__main__': unittest.main()
