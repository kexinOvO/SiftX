#!/usr/bin/env python3
"""Package the signed app together with matching offline third-party source materials."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import json
from prepare_third_party import ROOT, SOURCE_PACKAGE, digest, prepare


def canonical_macho_digest(path, temporary, name):
    copy = temporary / name
    shutil.copyfile(path, copy)
    result = subprocess.run(["codesign", "--remove-signature", str(copy)], capture_output=True, text=True)
    if result.returncode and "not signed at all" not in result.stderr:
        raise RuntimeError(f"Cannot compare signed executable {path}: {result.stderr}")
    # Removing a signature can leave __LINKEDIT.vmsize sized for the old signature.
    # Apply the same deterministic ad-hoc signature to both temporary copies to
    # normalize that metadata; every resulting byte, including code/data, is compared.
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                    "--identifier", "com.siftx.source-comparison", str(copy)],
                   check=True, capture_output=True, text=True)
    return digest(copy)


def verify_app_runtime(resources):
    """Compare built tools with audited inputs while allowing only Apple signature changes."""
    entries = json.loads((ROOT / "ThirdParty/runtime-files.json").read_text())["files"]
    expected_tools = set()
    with tempfile.TemporaryDirectory(prefix="siftx-runtime-compare-") as temporary:
        temporary = Path(temporary)
        for entry in entries:
            source = ROOT / entry["path"]
            relative = source.relative_to(ROOT / "App/Resources")
            target = resources / relative
            if "_CodeSignature" in relative.parts:
                continue
            if relative.parts[0] == "YouTubeTools":
                expected_tools.add(str(relative))
            if "symlink" in entry:
                valid = target.is_symlink() and str(target.readlink()) == entry["symlink"]
            else:
                valid = target.is_file() and not target.is_symlink()
                if valid and digest(target) != entry["sha256"]:
                    with source.open("rb") as stream:
                        magic = stream.read(4)
                    if magic in [b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
                                 b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"]:
                        valid = (canonical_macho_digest(source, temporary, "source") ==
                                 canonical_macho_digest(target, temporary, "target"))
                    else:
                        valid = False
            if not valid:
                raise RuntimeError(f"Built runtime differs from source materials: {relative}")
        actual_tools = {str(path.relative_to(resources))
                        for path in (resources / "YouTubeTools").rglob("*")
                        if (path.is_file() or path.is_symlink())
                        and "_CodeSignature" not in path.relative_to(resources).parts}
        if actual_tools != expected_tools:
            raise RuntimeError("Built app contains a different parser runtime file inventory")


def package():
    prepare()
    app = ROOT / "Build/SiftX.app"
    if not app.is_dir():
        raise RuntimeError("Build/SiftX.app is missing; run Scripts/build_release.sh")
    resources = app / "Contents/Resources"
    for name in ["ThirdParty-LICENSES.txt", "ThirdParty-SOURCE-NOTICE.txt"]:
        if not (resources / name).is_file() or digest(resources / name) != digest(ROOT / "App/Resources" / name):
            raise RuntimeError(f"Built app has missing or stale {name}; rebuild before distribution")
    verify_app_runtime(resources)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    output = SOURCE_PACKAGE.parent / f"SiftX-{version}-{build}-macOS-arm64.zip"
    with tempfile.TemporaryDirectory(dir=output.parent, prefix="distribution-") as temporary:
        stage = Path(temporary) / "SiftX"
        stage.mkdir()
        subprocess.run(["ditto", str(app), str(stage / "SiftX.app")], check=True)
        for path in [SOURCE_PACKAGE, SOURCE_PACKAGE.with_suffix(".zip.sha256"), ROOT / "THIRD_PARTY.md"]:
            shutil.copy2(path, stage / path.name)
        (stage / "READ-ME.txt").write_text(
            "SiftX for macOS (Apple silicon)\n\n"
            "SiftX.app is accompanied by SiftX-ThirdParty-Sources.zip.\n"
            "The source package includes original source archives, licenses, build instructions,\n"
            "pinned versions and SHA-256 checksums for the bundled third-party tools.\n"
            "Retain these materials when redistributing this download.\n\n"
            "第三方源码、许可证和构建说明在同级 SiftX-ThirdParty-Sources.zip 中。\n"
            "再次分发本下载包时，请保留配套材料。\n")
        staged = Path(temporary) / output.name
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(staged)], check=True)
        staged.replace(output)
    output.with_suffix(".zip.sha256").write_text(f"{digest(output)}  {output.name}\n")
    print(f"Distribution package: {output}")


if __name__ == "__main__":
    package()
