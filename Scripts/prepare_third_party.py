#!/usr/bin/env python3
"""Verify pinned source inputs and generate offline third-party release materials."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
THIRD_PARTY = ROOT / "ThirdParty"
SOURCE_PACKAGE = ROOT / "Build/Distribution/SiftX-ThirdParty-Sources.zip"


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def verify_runtime():
    inventory = json.loads((THIRD_PARTY / "runtime-files.json").read_text())
    expected_tools = set()
    for entry in inventory["files"]:
        path = ROOT / entry["path"]
        if entry["path"].startswith("App/Resources/YouTubeTools/"):
            expected_tools.add(entry["path"])
        if "symlink" in entry:
            valid = path.is_symlink() and str(path.readlink()) == entry["symlink"]
        else:
            valid = path.is_file() and not path.is_symlink() and digest(path) == entry["sha256"]
        if not valid:
            raise RuntimeError(f"Runtime differs from audited source inventory: {entry['path']}")
    actual_tools = {str(path.relative_to(ROOT))
                    for path in (ROOT / "App/Resources/YouTubeTools").rglob("*")
                    if path.is_file() or path.is_symlink()}
    if actual_tools != expected_tools:
        raise RuntimeError("YouTubeTools file inventory changed; audit versions and refresh source materials")


def source_path(entry):
    path = THIRD_PARTY / entry["archive"]
    if not path.resolve().is_relative_to((THIRD_PARTY / "Sources").resolve()):
        raise RuntimeError("Source archive must be inside ThirdParty/Sources")
    return path


def fetch_missing(components):
    for entry in components:
        path = source_path(entry)
        if path.exists():
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="siftx-source-") as temporary:
            download = Path(temporary) / "archive"
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                            "--retry", "2", "--connect-timeout", "20", "--max-time", "180",
                            "--output", str(download), entry["url"]], check=True)
            if digest(download) != entry["sha256"]:
                raise RuntimeError(f"Source checksum mismatch: {entry['name']}")
            # Stage on the same filesystem so an interrupted copy never becomes a source input.
            staged = path.with_suffix(path.suffix + ".partial")
            staged.write_bytes(download.read_bytes())
            staged.replace(path)


def license_members(path):
    """Read license files without extracting upstream archive paths onto the filesystem."""
    def wanted(name):
        parts = Path(name).parts
        base = parts[-1].lower()
        return (len(parts) == 2 and any(base.startswith(prefix)
                for prefix in ("license", "licence", "copying", "copyright", "notice", "unlicense")))
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            return [(item.filename, archive.read(item)) for item in archive.infolist()
                    if not item.is_dir() and wanted(item.filename)]
    with tarfile.open(path, "r:*") as archive:
        result = []
        for member in archive.getmembers():
            if member.isfile() and wanted(member.name):
                with archive.extractfile(member) as stream:
                    result.append((member.name, stream.read()))
        return result


def verify_sources(components):
    paths = [entry["archive"] for entry in components]
    if len(paths) != len(set(paths)):
        raise RuntimeError("Source manifest has duplicate archive paths")
    for entry in components:
        path = source_path(entry)
        if not path.is_file() or digest(path) != entry["sha256"]:
            raise RuntimeError(f"Missing or changed source: {entry['archive']}; run with --fetch for missing files")
        if not license_members(path):
            raise RuntimeError(f"No root license/notice found in source archive: {entry['archive']}")
    checksums = dict((line.split()[1], line.split()[0]) for line in
                     (THIRD_PARTY / "Upstream/yt-dlp-2026.08.19-SHA2-256SUMS").read_text().splitlines())
    release = next(entry for entry in components if entry["name"] == "yt-dlp")
    if release["sha256"] != checksums["yt-dlp.tar.gz"]:
        raise RuntimeError("yt-dlp source does not match the published release checksum")
    ffmpeg = next(entry for entry in components if entry["name"] == "FFmpeg")
    if ffmpeg["sha256"] != "733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1":
        raise RuntimeError("FFmpeg source no longer matches the documented build")


def material_files(components):
    files = {}
    for relative in ["THIRD_PARTY.md", "ThirdParty/README.md", "ThirdParty/BUILDING.md",
                     "ThirdParty/PROVENANCE.md", "ThirdParty/sources.lock.json",
                     "ThirdParty/runtime-files.json", "ThirdParty/Licenses/GPL-3.0.txt",
                     "Scripts/build_media_tool.sh", "Scripts/fetch_youtube_tools.py",
                     "Scripts/normalize_youtube_tools.py", "Scripts/sign_youtube_tools.py",
                     "Scripts/prepare_third_party.py", "Scripts/package_distribution.py",
                     "Scripts/generate_project.py", "Scripts/prepare_release_products.py",
                     "Scripts/build_release.sh", "Config/MediaTool.entitlements"]:
        path = ROOT / relative
        files[relative] = path.read_bytes()
    for path in sorted((THIRD_PARTY / "Upstream").iterdir()):
        if path.is_file():
            files[str(path.relative_to(ROOT))] = path.read_bytes()
    for name in ["FFmpeg-LICENSE.txt", "YouTube-THIRD-PARTY-LICENSES.txt",
                 "yt-dlp-LICENSE.txt", "QuickJS-LICENSE.txt", "ThirdParty-SOURCE-NOTICE.txt"]:
        files["Notices/" + name] = (ROOT / "App/Resources" / name).read_bytes()
    index = ["# Source and license inventory", "",
             "Full original sources retain nested notices. Build-only tools are labelled separately.", "",
             "| Component | Version | Role | License summary | Source archive |",
             "| --- | --- | --- | --- | --- |"]
    for entry in components:
        slug = re.sub(r"[^a-z0-9]+", "-", entry["name"].lower()).strip("-")
        for name, content in license_members(source_path(entry)):
            files[f"Licenses/{slug}--{Path(name).name}"] = content
        index.append(f"| {entry['name']} | {entry['version']} | {entry['role']} | "
                     f"{entry['license']} | ThirdParty/{entry['archive']} |")
    files["INDEX.md"] = ("\n".join(index) + "\n").encode()
    return files


def prepare(fetch=False, verify_only=False):
    components = json.loads((THIRD_PARTY / "sources.lock.json").read_text())["components"]
    verify_runtime()
    if fetch:
        fetch_missing(components)
    verify_sources(components)
    if verify_only:
        print(f"Verified runtime inventory and {len(components)} source archives.")
        return
    files = material_files(components)
    # The complete source archive itself carries every component's original license.
    notices = (ROOT / "App/Resources/YouTube-THIRD-PARTY-LICENSES.txt").read_text()
    notices += "\n\nADDITIONAL SOURCE AND BUILD TOOL NOTICES\n"
    for name, content in sorted(files.items()):
        if name.startswith("Licenses/"):
            notices += f"\n\n{'-' * 80}\n{name}\n{'-' * 80}\n" + content.decode("utf-8", errors="replace")
    notices += "\n\n" + (THIRD_PARTY / "Licenses/GPL-3.0.txt").read_text()
    (ROOT / "App/Resources/ThirdParty-LICENSES.txt").write_text(notices)
    files["Notices/ThirdParty-LICENSES.txt"] = notices.encode()
    sums = {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}
    for entry in components:
        sums["ThirdParty/" + entry["archive"]] = entry["sha256"]
    files["SHA256SUMS"] = ("\n".join(f"{value}  {name}" for name, value in sorted(sums.items())) + "\n").encode()
    SOURCE_PACKAGE.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=SOURCE_PACKAGE.parent, prefix="source-package-") as temporary:
        staged = Path(temporary) / SOURCE_PACKAGE.name
        with zipfile.ZipFile(staged, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for name, content in sorted(files.items()):
                info = zipfile.ZipInfo("SiftX-ThirdParty-Sources/" + name, (2026, 10, 7, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, content)
            for entry in components:
                info = zipfile.ZipInfo("SiftX-ThirdParty-Sources/ThirdParty/" + entry["archive"],
                                       (2026, 10, 7, 0, 0, 0))
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, source_path(entry).read_bytes())
        staged.replace(SOURCE_PACKAGE)
    SOURCE_PACKAGE.with_suffix(".zip.sha256").write_text(f"{digest(SOURCE_PACKAGE)}  {SOURCE_PACKAGE.name}\n")
    print(f"Prepared {len(components)} source archives: {SOURCE_PACKAGE}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true", help="Download missing pinned source archives")
    parser.add_argument("--verify-only", action="store_true", help="Check materials without writing output")
    args = parser.parse_args()
    prepare(fetch=args.fetch, verify_only=args.verify_only)
