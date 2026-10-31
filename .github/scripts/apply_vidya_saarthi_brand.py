"""Install the single, user-reviewed Vidya Saarthi app icon in generated Flutter platforms.

Only branding resources are replaced. No school documents or sync data are
accessed. GitHub CI runs this after flutter create for each target platform.
Windows ICO additionally uses Pillow to generate correct Windows Shell sizes (16–256px).
"""
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "assets" / "vidya_saarthi_app_icon.png"
PNG_SIGNATURE = bytes((137, 80, 78, 71, 13, 10, 26, 10))

def install():
    original = SOURCE.read_bytes()
    if not original.startswith(PNG_SIGNATURE):
        raise SystemExit("Branded icon must be a valid PNG")
    width, height = struct.unpack(">II", original[16:24])
    if (width, height) != (128, 128):
        raise SystemExit("Unexpected logo dimensions; refusing mismatched icon")
    # A single 128px PNG-in-ICO does not provide reliable small Windows Shell
    # sizes. Flutter's exe, taskbar, Inno Setup and shortcuts all use this ICO.
    # The native Windows build installs Pillow before running this helper.
    icon = ROOT / "windows/runner/resources/app_icon.ico"
    if icon.parent.exists():
        from PIL import Image

        sizes = [(16, 16), (24, 24), (32, 32), (48, 48),
                 (64, 64), (128, 128), (256, 256)]
        with Image.open(SOURCE) as source:
            branded = source.convert("RGBA").resize(
                (256, 256), Image.Resampling.LANCZOS
            )
            branded.save(icon, format="ICO", sizes=sizes)
        with Image.open(icon) as verified:
            embedded = set(verified.ico.sizes())
            if not set(sizes).issubset(embedded):
                raise SystemExit("Windows icon sizes missing: " + str(set(sizes) - embedded))
        print("Windows multi-resolution icon updated:", icon.relative_to(ROOT))

    android_root = ROOT / "android/app/src/main/res"
    if android_root.exists():
        count = 0
        for bucket in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
            destination = android_root / ("mipmap-" + bucket) / "ic_launcher.png"
            if destination.parent.exists():
                destination.write_bytes(original)
                count += 1
            round_icon = destination.with_name("ic_launcher_round.png")
            if round_icon.exists():
                round_icon.write_bytes(original)
        if count == 0:
            raise SystemExit("Android launcher-icon folders missing")
        print("Android launcher icons updated:", count)

    web = ROOT / "web"
    if web.exists():
        count = 0
        for relative in (
            "favicon.png",
            "icons/Icon-192.png",
            "icons/Icon-512.png",
            "icons/Icon-maskable-192.png",
            "icons/Icon-maskable-512.png",
        ):
            dest = web / relative
            if dest.parent.exists():
                dest.write_bytes(original)
                count += 1
        if count == 0:
            raise SystemExit("Flutter web icon folder missing")
        print("Web branding icons updated:", count)

if __name__ == "__main__":
    install()
