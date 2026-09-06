import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    info_path = next(name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist"))
    root = info_path.removesuffix("Info.plist")
    info = plistlib.loads(archive.read(info_path))
    assert info.get("NSSiriUsageDescription"), "缺少 Siri 权限说明"
    assert "INPlayMediaIntent" in info.get("INIntentsSupported", []), "未注册媒体意图"
    assert info.get("UIApplicationSceneManifest", {}).get("UIApplicationSupportsMultipleScenes"), "应用内 Siri 媒体意图需要场景支持"
    for file in ["siri-bootstrap.js", "siri-background.js"]:
        assert len(archive.read(root + "assets/siri/" + file)) > 100, "Siri 后台模块未打包"
    assert any(name.startswith(root) and "Metadata.appintents/" in name for name in names), "App Intents 元数据未提取"
    print("PASS: Siri 权限、媒体意图、场景配置、后台模块和 App Intents 元数据")
