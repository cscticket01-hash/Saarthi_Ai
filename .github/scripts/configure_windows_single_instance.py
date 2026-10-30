"""Apply safe per-session Windows instance and invisible autostart support.

The build generates the native Flutter runner, so patch it before compilation.
Use one engine for foreground and background work: never let two processes open
the same SQLite database/outbox simultaneously.
"""
import re
from pathlib import Path

MARKER = '// VIDYA_SAARTHI_SINGLE_INSTANCE'
BACKGROUND_MARKER = '// VIDYA_SAARTHI_BACKGROUND_AUTOSTART'


def configure(source):
    if MARKER in source and BACKGROUND_MARKER in source:
        return source
    start = source.index('int APIENTRY wWinMain(')
    brace = source.index('{', start)
    title = re.search(r'window\.Create\(L"([^"\n]+)"', source)
    if not title:
        raise ValueError('Unknown Windows runner title; review instance guard.')
    if 'window.Show();' not in source:
        raise ValueError('Unknown Windows runner show path; do not ship a visible background app.')
    if 'int APIENTRY wWinMain' not in source:
        raise ValueError('Only the generated Win32 Flutter runner can be patched.')
    guard = r'''
  // VIDYA_SAARTHI_SINGLE_INSTANCE
  // A login-started invisible app IS the only local SQLite/outbox owner.
  // On a normal launch, reveal that existing instance instead of starting
  // another Flutter engine. Background duplicate launch must never steal focus.
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
        // An existing logon worker owns the same exact UI engine.
        // Show it on demand without touching credentials, outbox or files.
        ::ShowWindow(existing, SW_SHOW);
        if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
        ::SetForegroundWindow(existing);
      }
    }
    return EXIT_SUCCESS;
  }
'''.replace('__TITLE__', title.group(1))
    output = '#include <windows.h>\n#include <cwchar>\n' + source[:brace + 1] + guard + source[brace + 1:]
    output = output.replace('window.Show();', '''// VIDYA_SAARTHI_BACKGROUND_AUTOSTART
  // Keep the Flutter window hidden only at logon. Its event loop, school
  // verification and bounded delta-sync timers are identical to foreground.
  if (!saarthi_background) window.Show();''', 1)
    return output


if __name__ == '__main__':
    path = Path('windows/runner/main.cpp')
    path.write_text(configure(path.read_text(encoding='utf-8')), encoding='utf-8')
