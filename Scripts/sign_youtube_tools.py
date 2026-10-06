#!/usr/bin/env python3
"""Sign the copied runtime and its libraries with the app's identity."""
from pathlib import Path
import os
import subprocess
from normalize_youtube_tools import normalize_frameworks

if os.environ.get("CODE_SIGNING_ALLOWED") != "YES":
    raise SystemExit(0)
resources = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
entitlements = Path(os.environ["SRCROOT"]) / "Config/MediaTool.entitlements"
tools = resources / "YouTubeTools"
normalize_frameworks(tools)
magic_values = [b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"]
for path in sorted(tools.rglob("*")):
    if not path.is_file() or path.is_symlink() or any(parent.suffix == ".framework" for parent in path.parents):
        continue
    with path.open("rb") as stream:
        magic = stream.read(4)
    if magic not in magic_values:
        continue
    command = ["codesign", "--force", "--sign", identity]
    if path in [tools / "yt-dlp", tools / "qjs"]:
        command += ["--entitlements", str(entitlements)]
    subprocess.run(command + [str(path)], check=True)
# A framework keeps its own resource seal around the signed library.
for framework in tools.rglob("*.framework"):
    subprocess.run(["codesign", "--force", "--sign", identity, str(framework)], check=True)
