"""Restore versioned framework links flattened by the upstream ZIP or Xcode copy."""
from pathlib import Path
import shutil

def normalize_frameworks(tools):
    for framework in tools.rglob("*.framework"):
        versions = framework / "Versions"
        actual = sorted(path.name for path in versions.iterdir() if path.name != "Current" and path.is_dir())
        if len(actual) != 1:
            raise RuntimeError("Unexpected Python framework versions")
        for path, target in [(versions / "Current", actual[0]), (framework / "Python", "Versions/Current/Python"),
                             (framework / "Resources", "Versions/Current/Resources")]:
            if path.is_symlink():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
            elif path.exists():
                path.unlink()
            path.symlink_to(target)
        python = tools / "_internal/Python"
        if python.exists() or python.is_symlink():
            python.unlink()
        python.symlink_to("Python.framework/Python")
