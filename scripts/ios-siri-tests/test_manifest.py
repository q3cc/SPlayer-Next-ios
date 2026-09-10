import copy
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


class SiriManifestTests(unittest.TestCase):
    def setUp(self):
        self.info = plistlib.loads((ROOT / "src-tauri/Info.ios.plist").read_bytes())

    def check_package(self, info):
        # 用最小安装包验证检查器，避免把源 plist 正确误当成最终包正确。
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "test.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                root = "Payload/SPlayer.app/"
                archive.writestr(root + "Info.plist", plistlib.dumps(info))
                for name in ["siri-bootstrap.js", "siri-background.js"]:
                    archive.writestr(root + "assets/siri/" + name, " " * 101)
                archive.writestr(root + "Metadata.appintents/extract.actionsdata", "{}")
            return subprocess.run(
                [sys.executable, str(ROOT / "scripts/ios-siri-tests/verify-ipa.py"), str(path)],
                capture_output=True, text=True,
            )

    def test_current_manifest(self):
        result = self.check_package(self.info)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_registration_is_rejected(self):
        for key in ["INSupportedMediaCategories", "INAlternativeAppNames", "INIntentsSupported", "AVInitialRouteSharingPolicy"]:
            with self.subTest(key=key):
                info = copy.deepcopy(self.info)
                info.pop(key)
                self.assertNotEqual(self.check_package(info).returncode, 0)

    def test_wrong_media_category_is_rejected(self):
        self.info["INSupportedMediaCategories"] = ["INMediaCategoryPodcasts"]
        self.assertNotEqual(self.check_package(self.info).returncode, 0)

    def test_wrong_airplay_policy_is_rejected(self):
        self.info["AVInitialRouteSharingPolicy"] = "Default"
        self.assertNotEqual(self.check_package(self.info).returncode, 0)


if __name__ == "__main__":
    unittest.main()
