"""Verify the iOS-only fvp/MDK dependency, assets and CocoaPods wiring.

This runs before Flutter or CocoaPods so a missing asset, stale pin or
Swift-Package-Manager switch fails fast. It never downloads the SDK.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

FVP_REF = "e81637411c58a9ae28de246ee73ad06e3418f10e"
MDK_VERSION = "0.39.0"
APPLE_ARCHIVE = "mdk-sdk-apple.tar.xz"
REQUIRED_ASSETS = (
    "native/fvp/assets.lock.json",
    "native/fvp/NOTICE.md",
    "native/fvp/LICENSE-fvp.txt",
    "native/fvp/LICENSE-libass.txt",
    "native/fvp/mdk.podspec",
    "native/fvp/apple/metal_texture.inc",
    "native/fvp/configure.cmake",
    "native/fvp/resolve.cmake",
)


def _fail(message: str) -> None:
    raise SystemExit(f"fvp iOS configuration error: {message}")


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        _fail(f"cannot read {path}: {error}")


def verify(repo: Path) -> list[str]:
    repo = repo.resolve()
    messages: list[str] = []

    for relative in REQUIRED_ASSETS:
        path = repo / relative
        if not path.is_file() or path.stat().st_size == 0:
            _fail(f"missing or empty asset: {relative}")

    lock_path = repo / "native/fvp/assets.lock.json"
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        _fail(f"invalid assets.lock.json: {error}")
    if lock.get("version") != MDK_VERSION:
        _fail(f"MDK version must be {MDK_VERSION}, got {lock.get('version')!r}")
    apple = lock.get("assets", {}).get("apple", {})
    if apple.get("archive") != APPLE_ARCHIVE:
        _fail(f"Apple SDK archive must be {APPLE_ARCHIVE}")
    digest = apple.get("sha256", "")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        _fail("Apple SDK SHA-256 must be 64 lowercase hex characters")
    base = apple.get("baseUrl", lock.get("baseUrl", ""))
    if not base.startswith("https://github.com/wang-bin/mdk-sdk/releases/download/"):
        _fail("Apple SDK base URL must be the pinned GitHub release")
    messages.append(f"MDK {MDK_VERSION} apple {APPLE_ARCHIVE} {digest[:12]}…")

    root_pubspec = _read(repo / "pubspec.yaml")
    if not re.search(
        rf"fvp:\s*\n\s*git:\s*\n\s*url: https://github\.com/wang-bin/fvp\.git\s*\n\s*ref: {FVP_REF}\b",
        root_pubspec,
    ):
        _fail(f"root pubspec must pin fvp to {FVP_REF}")
    package_pubspec = _read(repo / "packages/bili_player/pubspec.yaml")
    if FVP_REF not in package_pubspec:
        _fail(f"bili_player must pin fvp to {FVP_REF}")
    for pubspec in (root_pubspec, package_pubspec):
        if "enable-swift-package-manager: false" in pubspec:
            break
    else:
        _fail("pubspec must keep flutter.config.enable-swift-package-manager: false")

    for asset in (
        "native/fvp/assets.lock.json",
        "native/fvp/NOTICE.md",
        "native/fvp/LICENSE-fvp.txt",
        "native/fvp/LICENSE-libass.txt",
        "native/fvp/mdk.podspec",
    ):
        if not re.search(rf"^    - {re.escape(asset)}$", root_pubspec, re.MULTILINE):
            _fail(f"root pubspec assets is missing {asset}")

    podfile = _read(repo / "ios/Podfile")
    if "pod 'mdk', :podspec => '../native/fvp/mdk.podspec'" not in podfile:
        _fail("ios/Podfile must install the pinned mdk podspec")
    if "tool/prepare-fvp-apple.py" not in podfile:
        _fail("ios/Podfile must stage the pinned fvp Apple renderer")
    if "platform :ios, '15.0'" not in podfile:
        _fail("ios/Podfile deployment target changed")

    podspec = _read(repo / "native/fvp/mdk.podspec")
    if "assets.lock.json" not in podspec or "vendored_frameworks" not in podspec:
        _fail("mdk.podspec must read assets.lock.json and vendor mdk.xcframework")

    notice = _read(repo / "native/fvp/NOTICE.md")
    if FVP_REF not in notice:
        _fail("native/fvp/NOTICE.md must record the pinned fvp revision")

    prepare = _read(repo / "tool/prepare-fvp-apple.py")
    match = re.search(r'SOURCE_SHA256 = "([0-9a-f]{64})"', prepare)
    if not match:
        _fail("prepare-fvp-apple.py must verify the FvpPlugin.mm digest")
    staged = repo / "build/apple-plugins/ios/fvp/darwin/Classes/FvpPlugin.mm"
    if staged.is_file():
        actual = hashlib.sha256(staged.read_bytes()).hexdigest()
        if actual != match.group(1):
            _fail("staged FvpPlugin.mm does not match the reviewed digest")
        messages.append("staged FvpPlugin.mm digest verified")
    else:
        messages.append("staged FvpPlugin.mm not present; digest checked after pod install")

    for license_name in ("LICENSE-fvp.txt", "LICENSE-libass.txt"):
        text = _read(repo / f"native/fvp/{license_name}")
        if len(text) < 200:
            _fail(f"{license_name} looks truncated")
    return messages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    for message in verify(args.repo):
        print(message)
    print("fvp iOS dependency and CocoaPods configuration verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
