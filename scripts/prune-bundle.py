#!/usr/bin/env python3
"""Release builds ship only what the product renders. The source tree also holds the
design-QA catalogue (hundreds of Figma scenes and crops) used by the Debug-only
design catalog. Runs as a build phase on the built .app; Debug is left untouched."""
import os, re, sys

if os.environ.get("CONFIGURATION") != "Release":
    sys.exit(0)
app = os.path.join(os.environ["TARGET_BUILD_DIR"], os.environ["CONTENTS_FOLDER_PATH"])
src = os.path.join(os.environ["SRCROOT"], "Carezaar")

code = ""
for root, _, files in os.walk(src):
    if "/Resources" in root:
        continue
    for f in files:
        if f.endswith(".swift"):
            code += open(os.path.join(root, f), encoding="utf-8").read()

scenes = set(re.findall(r'key:\s*"([^"]+)"', code)) | set(re.findall(r'sceneKey\s*=\s*"([^"]+)"', code))
scene_dir = os.path.join(app, "Scenes")
scenes = {s for s in scenes if os.path.exists(os.path.join(scene_dir, s + ".json"))}
for key in list(scenes):
    text = open(os.path.join(scene_dir, key + ".json"), encoding="utf-8").read()
    scenes |= {t for t in re.findall(r'"stateTarget":\s*"([^"]+)"', text) if os.path.exists(os.path.join(scene_dir, t + ".json"))}
scene_text = "".join(open(os.path.join(scene_dir, s + ".json"), encoding="utf-8").read() for s in scenes)

removed = 0
for f in os.listdir(scene_dir):
    if f[:-5] not in scenes:
        os.remove(os.path.join(scene_dir, f)); removed += 1
asset_dir = os.path.join(app, "Assets")
for f in os.listdir(asset_dir):
    path = os.path.join(asset_dir, f)
    if os.path.isdir(path):  # Assets/app: product icons and art, all used by name
        continue
    if f.lower().endswith((".ttf", ".otf", ".woff2")) or f in scene_text or f'"{f}"' in code:
        continue
    os.remove(path); removed += 1
for f in os.listdir(app):
    if f.endswith("catalog.json"):
        os.remove(os.path.join(app, f)); removed += 1
print(f"prune-bundle: kept {len(scenes)} scenes; removed {removed} design-only files")
