#!/usr/bin/env python3
"""Patch generated Flutter Android project with ViunaLink branding/resources."""
from pathlib import Path
import shutil
import re

ROOT = Path(__file__).resolve().parents[1]
manifest = ROOT / "android/app/src/main/AndroidManifest.xml"
if not manifest.exists():
    raise SystemExit(f"Android manifest not found: {manifest}. Run flutter create first.")
text = manifest.read_text(encoding="utf-8")
for permission in ("android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE"):
    tag = f'<uses-permission android:name="{permission}" />'
    if permission not in text:
        text = text.replace("<application", f"    {tag}\n    <application", 1)
text = re.sub(r'android:label="[^"]*"', 'android:label="ViunaLink"', text, count=1)
if 'android:icon=' in text:
    text = re.sub(r'android:icon="[^"]*"', 'android:icon="@mipmap/ic_launcher"', text, count=1)
else:
    text = text.replace('<application', '<application android:icon="@mipmap/ic_launcher"', 1)
manifest.write_text(text, encoding="utf-8")

source = ROOT / "android-res"
target = ROOT / "android/app/src/main/res"
if source.exists():
    for item in source.iterdir():
        dest = target / item.name
        if item.is_dir():
            dest.mkdir(parents=True, exist_ok=True)
            for child in item.iterdir():
                if child.is_file():
                    target_file = dest / child.name
                    # Flutter's template creates PNG launcher icons in these
                    # density folders. A vector XML with the same resource
                    # name is a duplicate Android resource, so remove the
                    # generated PNG before installing the branded vector.
                    if child.suffix.lower() == ".xml":
                        png_file = target_file.with_suffix(".png")
                        if png_file.exists():
                            png_file.unlink()
                    shutil.copy2(child, target_file)
        elif item.is_file():
            shutil.copy2(item, dest)
print("Patched Android manifest and ViunaLink launcher icons")
