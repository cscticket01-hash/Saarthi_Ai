"""Build a separate test-backend bundle without editing production source."""
from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path


def bundle(destination, root=None):
    root = Path(root or Path(__file__).resolve().parent.parent)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    parts = []
    for filename in ("SaarthiSchool.gs", "SaarthiMobile.gs", "SaarthiStorage.gs", "SaarthiPlatform.gs"):
        source = (root / "school-backend" / filename).read_text(encoding="utf-8")
        if filename == "SaarthiSchool.gs":
            source, changed = re.subn(r"\bfunction\s+doPost\s*\(", "function VS_toolkitOriginalDoPost(", source)
            if changed != 1:
                raise ValueError("Expected exactly one original doPost; the backend protocol has changed")
        parts.append(source)
    parts.append((root / "toolkit" / "backend" / "ToolkitBridge.gs").read_text(encoding="utf-8"))
    combined = "\n\n".join(parts)
    if len(re.findall(r"\bfunction\s+doPost\s*\(", combined)) != 1:
        raise ValueError("Bundle must contain exactly one doPost")
    (destination / "Code.gs").write_text(combined, encoding="utf-8")
    for source, target in (("appsscript.json", "appsscript.json"), ("firestore.school.rules", "firestore.school.rules")):
        shutil.copyfile(root / "school-backend" / source, destination / target)
    shutil.copyfile(root / "toolkit" / "backend" / "SETUP.md", destination / "SETUP.md")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="build/test-backend")
    arguments = parser.parse_args()
    print(bundle(arguments.out))
