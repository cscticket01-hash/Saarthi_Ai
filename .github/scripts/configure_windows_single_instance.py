"""Patch Flutter's generated Windows runner before building the application.

Flutter 3.47 shows the window from flutter_window.cpp on the first frame,
not from main.cpp. Preserve the original show callback for ordinary launches.
"""
import re
from pathlib import Path

MARKER = '// VIDYA_SAARTHI_SINGLE_INSTANCE'
BACKGROUND_MARKER = '// VIDYA_SAARTHI_BACKGROUND_AUTOSTART'
SIZE_MARKER = '// VIDYA_SAARTHI_MINIMUM_WINDOW_SIZE'
MIN_WIDTH_DIP = 720
MIN_HEIGHT_DIP = 420


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
  DWORD instance_error = ::GetLastError();
  // Wait for the original singleton handle to disappear before opening SQLite.
  // Only explicit restart may wait; normal launches keep existing behavior.
  const bool saarthi_restart =
      ::wcsstr(::GetCommandLineW(), L"--saarthi-restart") != nullptr;
  if (saarthi_restart) {
    for (int attempt = 0; instance_gate.handle &&
         instance_error == ERROR_ALREADY_EXISTS && attempt < 150; ++attempt) {
      ::CloseHandle(instance_gate.handle);
      instance_gate.handle = nullptr;
      ::Sleep(100);
      instance_gate.handle = ::CreateMutexW(nullptr, FALSE, L"Local\\VidyaSaarthiSchoolApp");
      instance_error = ::GetLastError();
    }
  }
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


def configure_minimum_size(source):
    """Set a global native outer-window resize floor, scaled for monitor DPI."""
    if SIZE_MARKER in source:
        return source
    start = source.index('Win32Window::MessageHandler(')
    handler = source[start:]
    switch = '  switch (message) {'
    if handler.count(switch) != 1 or 'case WM_SIZE:' not in handler or 'case WM_GETMINMAXINFO:' in handler:
        raise ValueError('Unknown Windows message handler; refusing unsafe minimum-size patch.')
    if not re.search(r'\bHWND\s+hwnd\b', handler[:handler.index(switch)]) or not re.search(r'\bLPARAM\s+(?:const\s+)?lparam\b', handler[:handler.index(switch)]):
        raise ValueError('Unknown Windows message parameters; review minimum-size patch.')
    case = r'''
    case WM_GETMINMAXINFO: {
      // VIDYA_SAARTHI_MINIMUM_WINDOW_SIZE
      // Preserve system limits, maximize and normal Windows snap behaviour.
      ::DefWindowProcW(hwnd, message, wparam, lparam);
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      if (limits == nullptr) return 0;
      // Dynamic lookup keeps this compatible with the generated runner's SDK target.
      using DpiForWindow = UINT(WINAPI*)(HWND);
      const HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
      const auto get_dpi = user32 ? reinterpret_cast<DpiForWindow>(
          ::GetProcAddress(user32, "GetDpiForWindow")) : nullptr;
      const UINT measured_dpi = get_dpi ? get_dpi(hwnd) : 0;
      const UINT dpi = measured_dpi ? measured_dpi : 96;
      const LONG minimum_width = ::MulDiv(__WIDTH__, static_cast<int>(dpi), 96);
      const LONG minimum_height = ::MulDiv(__HEIGHT__, static_cast<int>(dpi), 96);
      if (limits->ptMinTrackSize.x < minimum_width)
        limits->ptMinTrackSize.x = minimum_width;
      if (limits->ptMinTrackSize.y < minimum_height)
        limits->ptMinTrackSize.y = minimum_height;
      return 0;
    }
'''.replace('__WIDTH__', str(MIN_WIDTH_DIP)).replace('__HEIGHT__', str(MIN_HEIGHT_DIP))
    return source[:start] + handler.replace(switch, switch + case, 1)


if __name__ == '__main__':
    main_path = Path('windows/runner/main.cpp')
    flutter_window_path = Path('windows/runner/flutter_window.cpp')
    win32_path = Path('windows/runner/win32_window.cpp')
    original_win32 = win32_path.read_text(encoding='utf-8')
    original_main = main_path.read_text(encoding='utf-8')
    original_window = flutter_window_path.read_text(encoding='utf-8')
    new_main = configure(original_main)
    new_window = configure_window(original_window)
    new_win32 = configure_minimum_size(original_win32)
    # Validate all runner components before writing any; fail closed on
    # unexpected Flutter template changes, with no half-patched build.
    main_path.write_text(new_main, encoding='utf-8')
    flutter_window_path.write_text(new_window, encoding='utf-8')
    win32_path.write_text(new_win32, encoding='utf-8')
