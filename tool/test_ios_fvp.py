"""Validate the iOS fvp/MDK wiring check without downloading the SDK."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest

from verify_fvp_ios import FVP_REF, MDK_VERSION, verify


ROOT = Path(__file__).resolve().parent.parent


class FvpIosConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name) / "repo"
        shutil.copytree(ROOT / "native/fvp", self.repo / "native/fvp")
        (self.repo / "ios").mkdir(parents=True)
        (self.repo / "tool").mkdir(parents=True)
        shutil.copyfile(ROOT / "tool/prepare-fvp-apple.py", self.repo / "tool/prepare-fvp-apple.py")
        shutil.copyfile(ROOT / "ios/Podfile", self.repo / "ios/Podfile")
        self.pubspec = (
            "name: bilisail\n"
            "flutter:\n"
            "  config:\n"
            "    enable-swift-package-manager: false\n"
            "  assets:\n"
            "    - native/fvp/assets.lock.json\n"
            "    - native/fvp/NOTICE.md\n"
            "    - native/fvp/LICENSE-fvp.txt\n"
            "    - native/fvp/LICENSE-libass.txt\n"
            "    - native/fvp/mdk.podspec\n"
            "dependencies:\n"
            "  fvp:\n"
            "    git:\n"
            "      url: https://github.com/wang-bin/fvp.git\n"
            f"      ref: {FVP_REF}\n"
        )
        (self.repo / "pubspec.yaml").write_text(self.pubspec, encoding="utf-8")
        (self.repo / "packages/bili_player").mkdir(parents=True)
        (self.repo / "packages/bili_player/pubspec.yaml").write_text(
            f"name: bili_player\nenvironment:\n  flutter: '>=3.50.0'\n"
            f"dependencies:\n  fvp:\n    git:\n      url: https://github.com/wang-bin/fvp.git\n      ref: {FVP_REF}\n",
            encoding="utf-8",
        )

    def test_repository_configuration_passes(self):
        messages = verify(self.repo)
        self.assertTrue(any(MDK_VERSION in message for message in messages))

    def test_swift_package_manager_must_remain_disabled(self):
        pubspec = self.pubspec.replace(
            "enable-swift-package-manager: false",
            "enable-swift-package-manager: true",
        )
        (self.repo / "pubspec.yaml").write_text(pubspec, encoding="utf-8")
        with self.assertRaises(SystemExit):
            verify(self.repo)

    def test_stale_fvp_revision_is_rejected(self):
        pubspec = self.pubspec.replace(FVP_REF, "0" * 40)
        (self.repo / "pubspec.yaml").write_text(pubspec, encoding="utf-8")
        with self.assertRaises(SystemExit):
            verify(self.repo)

    def test_missing_license_asset_is_rejected(self):
        (self.repo / "native/fvp/LICENSE-libass.txt").unlink()
        with self.assertRaises(SystemExit):
            verify(self.repo)

    def test_unpinned_apple_sdk_is_rejected(self):
        path = self.repo / "native/fvp/assets.lock.json"
        lock = json.loads(path.read_text(encoding="utf-8"))
        lock["assets"]["apple"]["sha256"] = "f" * 63
        path.write_text(json.dumps(lock), encoding="utf-8")
        with self.assertRaises(SystemExit):
            verify(self.repo)


if __name__ == "__main__":
    unittest.main()
