"""Patch Flutter's generated Windows runner before building the application.

Flutter 3.47 shows the window from flutter_window.cpp on the first frame,
not from main.cpp. Preserve the original show callback for ordinary launches.
"""
import re
from pathlib import Path

MARKER = '// VIDYA_SAARTHI_SINGLE_INSTANCE'
BACKGROUND_MARKER = '// VIDYA_SAARTHI_BACKGROUND_AUTOSTART'


def configure(source):
    """Patch main.cpp with the per-session SQLite process singleton."""
    if MARKER in source:
        return source
    start = source.index('int APIENTRY wWinMain(')
    brace = source.index('{', start)
    title = re.search(r'window\.Create\(L"([^"\n]+)"', source)
    if not title:
        raise ValueError('Unknown Windows runner title; review the instance guard.')
    guard = r'''
  // VIDYA_SAARTHI_SINGLE_INSTANCE
  // Exactly one per-session Flutter/SQLite/outbox owner.  Background starts
  // must not bring the existing UI to the foreground.
  const bool saarthi_background =
      ::wcsstr(::GetCommandLineW(), L"--saarthi-background") != nullptr;
  struct ScopedVidyaInstance {
    HANDLE handle;
    ~ScopedVidyaInstance() { if (handle) ::CloseHandle(handle); }
  } instance_gate{::CreateMutexW(nullptr, FALSE, L"Local\\VidyaSaarthiSchoolApp")};
  const DWORD instance_error = ::GetLastError();
  if (!instance_gate.handle) {
    ::MessageBoxW(nullptr, L"Unable to check the running school app. Close other instances and retry.",
                  L"Vidya Saarthi", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  if (instance_error == ERROR_ALREADY_EXISTS) {
    if (!saarthi_background) {
      HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"__TITLE__");
      if (existing) {
        ::ShowWindow(existing, SW_SHOW);
        if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
        ::SetForegroundWindow(existing);
      }
    }
    return EXIT_SUCCESS;
  }
'''.replace('__TITLE__', title.group(1))
    return '#include <windows.h>\n#include <cwchar>\n' + source[:brace + 1] + guard + source[brace + 1:]


def configure_window(source):
    """Patch flutter_window.cpp's actual first-frame Show() callback."""
    if BACKGROUND_MARKER in source:
        return source
    callback = '    this->Show();'
    if source.count(callback) != 1 or 'SetNextFrameCallback' not in source:
        raise ValueError('Unknown Flutter first-frame Show callback; refusing unsafe background patch.')
    replacement = '''    // VIDYA_SAARTHI_BACKGROUND_AUTOSTART
    // The hidden at-login process still pumps the same Flutter event loop.
    // Only visibility changes. A normal launch reveals this same HWND.
    if (::wcsstr(::GetCommandLineW(), L"--saarthi-background") == nullptr) {
      this->Show();
    }'''
    return '#include <cwchar>\n' + source.replace(callback, replacement, 1)


if __name__ == '__main__':
    main_path = Path('windows/runner/main.cpp')
    flutter_window_path = Path('windows/runner/flutter_window.cpp')
    original_main = main_path.read_text(encoding='utf-8')
    original_window = flutter_window_path.read_text(encoding='utf-8')
    new_main = configure(original_main)
    new_window = configure_window(original_window)
    # Validate both runner components before writing either; fail closed on
    # unexpected Flutter template changes, with no half-patched build.
    main_path.write_text(new_main, encoding='utf-8')
    flutter_window_path.write_text(new_window, encoding='utf-8')
