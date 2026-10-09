import unittest
from configure_windows_single_instance import configure, MARKER


class InstanceGuardTests(unittest.TestCase):
    def test_idempotent_and_before_flutter(self):
        source = 'int APIENTRY wWinMain(int n) { flutter::DartProject project(L"data"); window.Create(L"saarthi_ai", origin, size); }'
        result = configure(source)
        self.assertEqual(result.count(MARKER), 1)
        self.assertLess(result.index('CreateMutexW'), result.index('DartProject'))
        self.assertIn('ERROR_ALREADY_EXISTS', result)
        self.assertIn('CloseHandle', result)
        self.assertEqual(configure(result), result)

    def test_unknown_runner_fails_without_rewriting(self):
        with self.assertRaises(ValueError):
            configure('int APIENTRY wWinMain(int n) { unknown(); }')


if __name__ == '__main__':
    unittest.main()
