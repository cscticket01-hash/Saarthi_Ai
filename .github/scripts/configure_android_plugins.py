"""Use SDK 36 consistently in the resolved Android plugin runner copies."""
import json
import re
from pathlib import Path

plugins = json.loads(Path(".flutter-plugins-dependencies").read_text())
for plugin in plugins["plugins"].get("android", []):
    directory = Path(plugin["path"]) / "android"
    for filename in ["build.gradle", "build.gradle.kts"]:
        gradle = directory / filename
        if not gradle.exists():
            continue
        source = gradle.read_text()
        setting = r"\1compileSdk = 36" if filename.endswith(".kts") else r"\1compileSdkVersion 36"
        updated = re.sub(
            r"(?m)^([ \t]*)compileSdk(?:Version)?[ \t]*(?:=[ \t]*)?(?:\d+|flutter\.compileSdkVersion)[ \t]*$",
            setting, source)
        if updated != source:
            gradle.write_text(updated)
            print(plugin["name"], "uses Android SDK 36")
