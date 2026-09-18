# iOS 完全原生迁移

## 目标

iOS 版本最终使用 SwiftUI/UIKit 渲染所有可见页面，Vue/WKWebView 不再承担播放器、曲库、歌词、下载、云盘或设置界面。Rust/NAPI 音频能力继续保留为底层播放和解码服务；网络协议、缓存索引和文件任务迁移到 Swift 原生服务，避免在原生界面上继续依赖 `window.api`。

## 当前边界

当前仓库是 Tauri 应用，`src-tauri/tauri.conf.json` 的 `frontendDist` 指向 `dist-mobile`，iOS 宿主工程由 Tauri CLI 生成且没有提交到仓库。因此仅新增 SwiftUI 文件不会成为 App 入口，也不能称为完成原生化。完整迁移需要一个受 Xcode 管理的 iOS App target，并将 Tauri 仅作为过渡期的 Rust 音频插件或移除。

## 迁移顺序

### 第一阶段（已开始）

`src-tauri/ios-native` 已加入独立的 Swift Package，包含 SwiftUI 根导航、曲库空状态、播放队列空状态、设置入口、迷你播放器和原生播放器展示状态。该模块先独立验证状态与界面结构，等宿主 App target 建立后再接入音频桥接、文件导入和真实数据源。

1. 建立 `SPlayerNative` iOS App target、Swift Package 依赖和 App 生命周期；先保留现有 Tauri target 作为回滚入口。
2. 抽出原生 `PlaybackStore`、`LibraryStore`、`LyricsStore`、`DownloadStore`、`CacheStore` 和 `CloudStore`，所有状态通过 `ObservableObject`/`actor` 暴露给 SwiftUI。
3. 用 SwiftUI 重写 Tab 根导航、迷你播放器、全屏播放器、播放队列和媒体库；播放状态接入现有 `NativeAudioPlugin` 的 AVAudioSession/MPNowPlaying 能力。
4. 迁移歌词解析、逐字高亮、歌词缓存和 TTML 本地覆盖；歌词动画只在可见窗口运行。
5. 迁移设置、下载、离线缓存、云盘上传、文件导入和版权确认；原生文件选择器使用 `UIDocumentPickerViewController`，传输使用 `URLSession`。
6. 真机回归后切换 App target 为发布入口，再删除 WebView 入口和 `window.api` 移动端适配层。

## 功能验收

- 冷启动不创建 WKWebView，所有页面可在无网络时显示。
- 本地音频、在线音频、缓存命中、暂停/恢复、后台播放、锁屏控制和 AirPlay 正常。
- 歌词滚动与逐字高亮不依赖 JavaScript 定时器。
- 下载和云盘上传支持后台/前台切换、取消、重试、进度和文件安全范围。
- 设置、数据库、歌词和歌曲缓存迁移后不丢失，旧版本可以回滚。
- 在 iPhone 和 iPad 真机分别验证内存、耗电、旋转、Split View、文件导入和系统音频中断。

## 不能在当前环境完成的部分

当前环境没有 Xcode、iOS SDK、签名证书或真机，无法生成/编译/安装原生 App target，也不能声称完全原生迁移已经完成。现有 Vue/Tauri 页面必须继续保留，直到上述 target 建立并通过真机验收。
