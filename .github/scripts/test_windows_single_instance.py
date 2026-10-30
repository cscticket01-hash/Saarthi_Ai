import unittest
from configure_windows_single_instance import configure, configure_window, MARKER, BACKGROUND_MARKER


class InstanceGuardTests(unittest.TestCase):
    MAIN = ('int APIENTRY wWinMain(int n) { '
            'flutter::DartProject project(L"data"); '
            'window.Create(L"saarthi_ai", origin, size); }')
    WINDOW = ('bool FlutterWindow::OnCreate() { '
              'flutter_controller_->engine()->SetNextFrameCallback([&]() {\n'
              '    this->Show();\n'
              '  }); flutter_controller_->ForceRedraw(); return true; }')

    def test_idempotent_singleton_before_flutter(self):
        result = configure(self.MAIN)
        self.assertEqual(result.count(MARKER), 1)
        self.assertLess(result.index('CreateMutexW'), result.index('DartProject'))
        self.assertIn('ERROR_ALREADY_EXISTS', result)
        self.assertIn('CloseHandle', result)
        self.assertIn('GetCommandLineW()', result)
        self.assertIn('L"--saarthi-background"', result)
        self.assertIn('if (!saarthi_background) {', result)
        self.assertIn('::ShowWindow(existing, SW_SHOW)', result)
        self.assertIn('::SetForegroundWindow(existing)', result)
        self.assertEqual(configure(result), result)

    def test_flutter_3_47_first_frame_show_is_suppressed_for_hidden_login(self):
        result = configure_window(self.WINDOW)
        self.assertEqual(result.count(BACKGROUND_MARKER), 1)
        self.assertIn('SetNextFrameCallback', result)
        self.assertIn('this->Show();', result)
        self.assertIn('if (::wcsstr(::GetCommandLineW(), L"--saarthi-background") == nullptr)', result)
        self.assertEqual(configure_window(result), result)

    def test_no_second_flutter_engine_opening_same_school_sqlite(self):
        result = configure(self.MAIN)
        self.assertLess(result.index('ERROR_ALREADY_EXISTS'), result.index('DartProject'))
        self.assertLess(result.index('return EXIT_SUCCESS;'), result.index('DartProject'))

    def test_unknown_runner_fails_closed_without_rewriting(self):
        with self.assertRaises(ValueError):
            configure('int APIENTRY wWinMain(int n) { unknown(); }')
        with self.assertRaises(ValueError):
            configure_window('bool FlutterWindow::OnCreate() { return true; }')


if __name__ == '__main__':
    unittest.main()
