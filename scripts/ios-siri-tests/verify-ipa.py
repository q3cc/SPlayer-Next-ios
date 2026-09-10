import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    info_path = next(name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist"))
    root = info_path.removesuffix("Info.plist")
    info = plistlib.loads(archive.read(info_path))
    assert info.get("AVInitialRouteSharingPolicy") == "LongFormAudio", "缺少 AirPlay 音乐路由策略"
    assert info.get("NSSiriUsageDescription"), "缺少 Siri 权限说明"
    assert "INPlayMediaIntent" in info.get("INIntentsSupported", []), "未注册媒体意图"
    assert "INMediaCategoryMusic" in info.get("INSupportedMediaCategories", []), "未声明 Siri 音乐类别"
    assert info.get("CFBundleDisplayName") == "SPlayer", "Siri 应用显示名称不一致"
    aliases = {item.get("INAlternativeAppName") for item in info.get("INAlternativeAppNames", [])}
    assert {"SPlayer Next", "S Play", "SPlay"} <= aliases, "缺少 Siri 应用别名"
    assert info.get("UIApplicationSceneManifest", {}).get("UIApplicationSupportsMultipleScenes"), "应用内 Siri 媒体意图需要场景支持"
    for file in ["siri-bootstrap.js", "siri-background.js"]:
        assert len(archive.read(root + "assets/siri/" + file)) > 100, "Siri 后台模块未打包"
    assert any(name.startswith(root) and "Metadata.appintents/" in name for name in names), "App Intents 元数据未提取"
    print("PASS: Siri 名称、音乐类别、权限、媒体意图、场景配置、后台模块和 App Intents 元数据")
