"""Check the Safari configuration contract before doing runtime verification."""
import json
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SafariConfigurationTests(unittest.TestCase):
    def test_native_capabilities_are_direct_extension_children(self):
        extension = plistlib.loads((ROOT / "SafariExtension/Info.plist").read_bytes())["NSExtension"]
        self.assertEqual(extension["NSExtensionPointIdentifier"], "com.apple.Safari.extension")
        self.assertEqual(extension["SFSafariToolbarItem"]["Action"], "Popover")
        image = ROOT / "SafariExtension" / extension["SFSafariToolbarItem"]["Image"]
        self.assertEqual(image.suffix, ".png")
        self.assertTrue(image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(extension["SFSafariWebsiteAccess"]["Level"], "All")
        scripts = extension["SFSafariContentScript"]
        self.assertGreater(len(scripts), 0)
        for script in scripts:
            self.assertTrue((ROOT / "SafariExtension" / script["Script"]).is_file())

    def test_probe_click_uses_native_ui_without_a_web_popup(self):
        manifest = json.loads((ROOT / "MediaProbe/Resources/manifest.json").read_text())
        self.assertTrue(manifest["browser_action"]["default_title"])
        self.assertNotIn("default_popup", manifest["browser_action"])
        self.assertIn("nativeMessaging", manifest["permissions"])


if __name__ == "__main__":
    unittest.main()
