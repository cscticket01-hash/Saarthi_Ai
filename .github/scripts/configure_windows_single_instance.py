"""Apply a per-session native instance guard before Flutter/local storage starts."""
import re
from pathlib import Path

MARKER = '// VIDYA_SAARTHI_SINGLE_INSTANCE'


def configure(source):
    if MARKER in source:
        return source
    start = source.index('int APIENTRY wWinMain(')
    brace = source.index('{', start)
    title = re.search(r'window\.Create\(L"([^"\n]+)"', source)
    if not title:
        raise ValueError('Unknown Windows runner title; review the instance guard.')
    guard = r'''
  // VIDYA_SAARTHI_SINGLE_INSTANCE
  // Keep the handle alive for the entire process. A second Flutter engine must
  // never open the same local database or secure-storage file concurrently.
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
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"__TITLE__");
    if (existing) {
      if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }
'''.replace('__TITLE__', title.group(1))
    return '#include <windows.h>\n' + source[:brace + 1] + guard + source[brace + 1:]


if __name__ == '__main__':
    path = Path('windows/runner/main.cpp')
    path.write_text(configure(path.read_text(encoding='utf-8')), encoding='utf-8')
