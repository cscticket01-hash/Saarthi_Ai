import unittest
from configure_windows_single_instance import configure, MARKER, BACKGROUND_MARKER


class InstanceGuardTests(unittest.TestCase):
    SOURCE = ('int APIENTRY wWinMain(int n) { '
              'flutter::DartProject project(L"data"); '
              'window.Create(L"saarthi_ai", origin, size); '
              'window.Show(); }')

    def test_idempotent_before_flutter_and_hidden_autostart(self):
        result = configure(self.SOURCE)
        self.assertEqual(result.count(MARKER), 1)
        self.assertEqual(result.count(BACKGROUND_MARKER), 1)
        self.assertLess(result.index('CreateMutexW'), result.index('DartProject'))
        self.assertIn('ERROR_ALREADY_EXISTS', result)
        self.assertIn('CloseHandle', result)
        self.assertIn('GetCommandLineW()', result)
        self.assertIn('L"--saarthi-background"', result)
        self.assertIn('if (!saarthi_background) window.Show();', result)
        self.assertIn('if (!saarthi_background) {', result)
        self.assertIn('::ShowWindow(existing, SW_SHOW)', result)
        self.assertIn('::SetForegroundWindow(existing)', result)
        self.assertEqual(configure(result), result)

    def test_no_second_flutter_engine_opening_same_school_sqlite(self):
        result = configure(self.SOURCE)
        self.assertLess(result.index('ERROR_ALREADY_EXISTS'), result.index('flutter::DartProject'))
        self.assertLess(result.index('return EXIT_SUCCESS;'), result.index('flutter::DartProject'))

    def test_unknown_runner_fails_closed_without_rewriting(self):
        with self.assertRaises(ValueError):
            configure('int APIENTRY wWinMain(int n) { unknown(); }')
        with self.assertRaises(ValueError):
            configure('int APIENTRY wWinMain(int n) { window.Create(L"school", p, s); }')


if __name__ == '__main__':
    unittest.main()
