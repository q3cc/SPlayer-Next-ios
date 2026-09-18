"""运行 iPad 原生界面测试，并导出可直接检查的横屏截图。"""

import json
import subprocess
import time

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
device = next(
    device
    for runtime, values in devices["devices"].items()
    if "iOS-17-5" in runtime
    for device in values
    if "iPad" in device["name"]
)
subprocess.run([
    "xcodebuild", "-project", "SPlayerNative.xcodeproj", "-scheme", "SPlayerNative",
    "-destination", "platform=iOS Simulator,id=" + device["udid"],
    "-derivedDataPath", "build/ipad", "-resultBundlePath", "build/NativeIPadTests.xcresult",
    "-parallel-testing-enabled", "NO",
    "-only-testing:SPlayerNativeUITests/NativeAppTests/testWideLayoutMatchesOriginalStructure",
    "CODE_SIGNING_ALLOWED=NO", "test",
], check=True)
subprocess.run(["xcrun", "simctl", "launch", device["udid"], "top.imsyy.splayer-next.native", "--uitest-light"], check=True)
time.sleep(3)
subprocess.run(["xcrun", "simctl", "io", device["udid"], "screenshot", "build/native-ipad.png"], check=True)
