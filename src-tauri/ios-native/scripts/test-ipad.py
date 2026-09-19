"""运行 iPad 原生界面测试，并导出可直接检查的横屏截图。"""

import json
import subprocess
from pathlib import Path

EVIDENCE_FILES = {
    "SPlayer-iPad-home": "native-ipad.png",
    "SPlayer-iPad-library": "native-ipad-library.png",
    "SPlayer-iPad-playing": "native-ipad-playing.png",
    "SPlayer-iPad-accessibility": "native-ipad-accessibility.txt",
}


def read_result(bundle, reference=None):
    """读取 Xcode 15 的测试结果对象，不把二进制附件当作 JSON。"""
    command = ["xcrun", "xcresulttool", "get", "--path", str(bundle), "--format", "json"]
    if reference is not None:
        command.extend(["--id", reference])
    return json.loads(subprocess.check_output(command))


def export_evidence(bundle, directory):
    """导出测试断言时的附件，避免退出测试恢复竖屏后再截屏。"""
    directory.mkdir(parents=True, exist_ok=True)
    visited = set()
    exported = set()

    def visit(value):
        if isinstance(value, list):
            for child in value:
                visit(child)
        elif isinstance(value, dict):
            name = value.get("name")
            name = name.get("_value") if isinstance(name, dict) else None
            payload = value.get("payloadRef", {}).get("id", {}).get("_value")
            if name in EVIDENCE_FILES and payload and name not in exported:
                destination = directory / EVIDENCE_FILES[name]
                subprocess.run(
                    [
                        "xcrun", "xcresulttool", "export", "--type", "file",
                        "--path", str(bundle), "--id", payload,
                        "--output-path", str(destination),
                    ],
                    check=True,
                )
                exported.add(name)
                print(f"已导出 {destination}", flush=True)
            for key, child in value.items():
                if key in ("testsRef", "summaryRef"):
                    reference = child["id"]["_value"]
                    if reference not in visited:
                        visited.add(reference)
                        visit(read_result(bundle, reference))
                else:
                    visit(child)

    visit(read_result(bundle))
    return exported


def main():
    devices = json.loads(
        subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"])
    )
    device = next(
        device
        for runtime, values in devices["devices"].items()
        if "iOS-17-5" in runtime
        for device in values
        if "iPad" in device["name"]
    )
    bundle = Path("build/NativeIPadTests.xcresult")
    result = subprocess.run(
        [
            "xcodebuild", "-project", "SPlayerNative.xcodeproj", "-scheme", "SPlayerNative",
            "-destination", "platform=iOS Simulator,id=" + device["udid"],
            "-derivedDataPath", "build/ipad", "-resultBundlePath", str(bundle),
            "-parallel-testing-enabled", "NO",
            "-only-testing:SPlayerNativeUITests/NativeAppTests/testWideLayoutMatchesOriginalStructure",
            "CODE_SIGNING_ALLOWED=NO", "test",
        ],
        check=False,
    )
    exported = export_evidence(bundle, bundle.parent) if bundle.exists() else set()
    result.check_returncode()
    missing = EVIDENCE_FILES.keys() - exported
    if missing:
        raise RuntimeError("缺少界面验证附件：" + ", ".join(sorted(missing)))


if __name__ == "__main__":
    main()
