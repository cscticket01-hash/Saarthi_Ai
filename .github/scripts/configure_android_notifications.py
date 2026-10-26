"""Configure the generated Android runner for local school notifications."""
import re
from pathlib import Path

app = Path("android/app")
gradle = app / "build.gradle.kts"
kotlin = gradle.exists()
if not kotlin:
    gradle = app / "build.gradle"
source = gradle.read_text()
flag = "isCoreLibraryDesugaringEnabled = true" if kotlin else "coreLibraryDesugaringEnabled true"
if "coreLibraryDesugaringEnabled" not in source and "isCoreLibraryDesugaringEnabled" not in source:
    source, count = re.subn(r"compileOptions\s*\{", "compileOptions {\n        " + flag, source, count=1)
    if count != 1:
        raise SystemExit("Android compileOptions block is missing")
if "desugar_jdk_libs" not in source:
    dependency = ('coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")' if kotlin
                  else 'coreLibraryDesugaring "com.android.tools:desugar_jdk_libs:2.1.4"')
    source += "\ndependencies {\n    " + dependency + "\n}\n"
source = re.sub(r"(?m)^(\s*)compileSdk\s*=.*$", r"\1compileSdk = 36", source) if kotlin else re.sub(
    r"(?m)^(\s*)compileSdk(?:Version)?\s*(?:=\s*)?[^\n]+$", r"\1compileSdkVersion 36", source)
gradle.write_text(source)
print("Android SDK 36 and notification desugaring configured")
