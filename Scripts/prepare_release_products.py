#!/usr/bin/env python3
"""Discard generated Debug bundles before Release; preserve logs, archives and caches."""
from pathlib import Path
import shutil

build = Path(__file__).resolve().parents[1] / "Build"
for name in ["SiftX.app", "SiftXSafariExtension.appex", "SiftXMediaProbe.appex"]:
    bundle = build / name
    executables = bundle / "Contents/MacOS"
    if list(executables.glob("*.debug.dylib")) or (executables / "__preview.dylib").exists():
        shutil.rmtree(bundle)
