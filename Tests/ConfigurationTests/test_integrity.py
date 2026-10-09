"""Regression tests for native/web extension packaging contracts.

These checks intentionally run without Xcode or a Safari installation.
"""
import json
from pathlib import Path
import plistlib
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
GROUP_KEY = "com.apple.security.application-groups"
APP_GROUP = "$(DEVELOPMENT_TEAM).com.siftx.shared"


def plist(relative_path):
    return plistlib.loads((ROOT / relative_path).read_bytes())


class PackagingIntegrityTests(unittest.TestCase):
    def test_all_native_targets_share_a_sandboxed_app_group(self):
        components = [
            ("Config/App-Info.plist", "Config/App.entitlements"),
            ("SafariExtension/Info.plist", "SafariExtension/SafariExtension.entitlements"),
            ("MediaProbe/Info.plist", "MediaProbe/MediaProbe.entitlements"),
        ]
        for info_path, entitlement_path in components:
            with self.subTest(target=info_path):
                self.assertEqual(plist(info_path)["SiftXAppGroupIdentifier"], APP_GROUP)
                entitlements = plist(entitlement_path)
                self.assertTrue(entitlements["com.apple.security.app-sandbox"])
                self.assertEqual(entitlements[GROUP_KEY], [APP_GROUP])

    def test_web_extension_declares_all_existing_scripts_in_load_order(self):
        manifest = json.loads((ROOT / "MediaProbe/Resources/manifest.json").read_text())
        self.assertEqual(manifest["manifest_version"], 2)
        self.assertEqual(manifest["background"]["scripts"][:1], ["probe-core.js"])
        self.assertEqual(manifest["content_scripts"][0]["js"][:1], ["probe-core.js"])
        for entry in manifest["background"]["scripts"]:
            with self.subTest(script=entry):
                self.assertTrue((ROOT / "MediaProbe/Resources" / entry).is_file())
        for group in manifest["content_scripts"]:
            for entry in group["js"]:
                with self.subTest(script=entry):
                    self.assertTrue((ROOT / "MediaProbe/Resources" / entry).is_file())

    def test_safari_extension_points_match_the_two_extension_types(self):
        self.assertEqual(
            plist("SafariExtension/Info.plist")["NSExtension"]["NSExtensionPointIdentifier"],
            "com.apple.Safari.extension",
        )
        self.assertEqual(
            plist("MediaProbe/Info.plist")["NSExtension"]["NSExtensionPointIdentifier"],
            "com.apple.Safari.web-extension",
        )

    def test_xcode_scheme_includes_native_download_regression_tests(self):
        scheme = ET.parse(ROOT / "SiftX.xcodeproj/xcshareddata/xcschemes/SiftX.xcscheme")
        targets = {
            element.attrib.get("BlueprintName")
            for element in scheme.findall(".//TestAction//TestableReference//BuildableReference")
        }
        self.assertIn("SiftXDownloadTests", targets)


if __name__ == "__main__":
    unittest.main()
