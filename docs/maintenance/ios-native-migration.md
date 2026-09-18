# iOS 完全原生迁移

## 目标与当前状态

最终目标是迁移现有 iOS 产品的全部功能，而不是在 WebView 上覆盖原生外壳。

当前已建立独立 SwiftUI 应用入口和真实的本地音乐播放实现。它不加载 Tauri、JavaScript 或 WebView，也不依赖旧应用运行。它仍是**本地音乐原生预览版，不是完整功能替代品**。原 Tauri 版本继续保留。

## 工程与构建

- Swift Package：`src-tauri/ios-native/Package.swift`。
- App 入口：`src-tauri/ios-native/App/SPlayerNativeApp.swift`。
- XcodeGen 工程定义：`src-tauri/ios-native/project.yml`；在 macOS 安装 XcodeGen 后，在该目录运行 `xcodegen generate`。
- 原生 Bundle ID：`top.imsyy.splayer-next.native`，与旧应用并存，不覆盖用户数据。
- GitHub Actions：`.github/workflows/ios-native-ui.yml`，执行 macOS 包编译/测试、iOS 模拟器编译、真机目标未签名编译及模拟器 UI 测试。
- 构建成功后上传 `SPlayerNative-build`，包含未签名 IPA 和 UI 测试结果。未签名 IPA 不能直接安装，需要有效签名；不代表通过 App Store 发布审核。
- 无需以缺少本地 Xcode 为由停止开发，编译与模拟器验证可交给 Actions。真机音频、AirPlay、耗电与内存仍需设备验收。

## 已接入的功能

- 原生曲库、搜索、多选文件导入、删除确认与原文件保护。
- AVFoundation 读取音频元数据；文件复制和索引写入由 actor 处理，索引原子写入。
- 本地曲库跨启动保存，索引保存相对路径，适应沙盒根目录变化。
- AVPlayer 真实播放/暂停、上一首/下一首、进度拖动、顺序播放与单曲循环。
- 队列重排和移除、迷你播放器与完整播放页。
- 锁屏媒体信息与控制、音频中断处理、耳机拔出暂停、系统音量与 AirPlay 选择。
- 导入 UTF-8 LRC、按毫秒解析、多时间戳、逐行高亮滚动和点击跳转。
- 浅色/深色/系统主题偏好保存，应用后台暂停界面位置刷新。

原生预览版暂用系统 AVPlayer，并未接入旧插件的 AudioStreaming/均衡器能力，格式支持可能与旧版不同。不支持的文件会报告导入或播放失败，不会伪造播放成功。

## 尚未迁移的功能

- 网易云、QQ 音乐、酷狗账号认证、推荐、搜索、歌单与在线音源解析。
- Subsonic/Jellyfin/Emby 服务器、账号凭据安全存储与协议适配。
- 下载任务、容量限制的歌曲缓存、云盘上传和任务恢复。
- 自动歌词匹配、TTML/逐字歌词、歌词画中画、Siri、均衡器。
- 封面提取与展示、持久播放队列/进度恢复、多语言界面。
- 旧版配置、曲库及下载记录迁移。独立 Bundle ID 不会自动读取旧应用的沙盒。

未实现功能不使用空按钮或假成功结果替代，设置页会说明当前功能边界。完整迁移必须完成以上缺口后才能替换原应用。

## 验收

单元测试覆盖无歌曲不假播放、缺失文件报错、歌词时间解析、音频导入后重建索引和删除不影响原文件。UI 测试验证独立应用启动、Tab 导航及页面不存在 WebView，并保留截图。

还需真机验证：多格式音乐、iCloud 文件下载后导入、后台连续播放、来电恢复、蓝牙/有线耳机拔出、AirPlay、旋转/iPad 布局、实际音频输出和内存峰值。模拟器 UI 测试不等于这些场景已通过。
