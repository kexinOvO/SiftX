#!/usr/bin/env python3
"""Fetch pinned upstream tools; preserve the onedir layout required by App Sandbox."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tempfile
from normalize_youtube_tools import normalize_frameworks

ROOT = Path(__file__).resolve().parents[1]
ASSETS = [
    ("https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos.zip", "yt-dlp.zip", "07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8"),
    ("https://github.com/quickjs-ng/quickjs/releases/download/v0.17.0/qjs-darwin-arm64", "qjs", "8be3ddfe3397d2e692e4e1e8972ee9d032a0a580505d2f8b4ea528cf1b651c11"),
]

with tempfile.TemporaryDirectory(prefix="siftx-youtube-") as temporary:
    work = Path(temporary)
    for url, name, digest in ASSETS:
        target = work / name
        subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--output", str(target), url], check=True)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise RuntimeError("Upstream checksum mismatch: " + name)
    tools = work / "YouTubeTools"
    subprocess.run(["ditto", "-x", "-k", str(work / "yt-dlp.zip"), str(tools)], check=True)
    normalize_frameworks(tools)
    (tools / "yt-dlp_macos").rename(tools / "yt-dlp")
    shutil.copy2(work / "qjs", tools / "qjs")
    (tools / "qjs").chmod(0o755)
    # SiftX currently targets arm64. Remove the unused slice before signing.
    for path in tools.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in [b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"]:
            thin = path.with_name(path.name + ".arm64")
            subprocess.run(["lipo", str(path), "-thin", "arm64", "-output", str(thin)], check=True)
            thin.chmod(path.stat().st_mode)
            thin.replace(path)
    destination = ROOT / "App/Resources/YouTubeTools"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(tools, destination, symlinks=True)
    for url, name in [
        ("https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/THIRD_PARTY_LICENSES.txt", "YouTube-THIRD-PARTY-LICENSES.txt"),
        ("https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/LICENSE", "yt-dlp-LICENSE.txt"),
        ("https://raw.githubusercontent.com/quickjs-ng/quickjs/v0.17.0/LICENSE", "QuickJS-LICENSE.txt"),
    ]:
        subprocess.run(["curl", "--fail", "--location", "--output", str(ROOT / "App/Resources" / name), url], check=True)
print("Pinned YouTube tools installed. Rebuild SiftX to sign sandbox helpers.")
