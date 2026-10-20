# iPad 原生版本

## 使用与实现

原生应用保留 B 版首页、侧栏、搜索和迷你播放器的内容结构；全屏播放器参考 [Apple Music-like Lyrics](https://github.com/Steve-xmh/applemusic-like-lyrics) 的封面取色背景、双栏布局和歌词层级。导航和悬浮控制使用系统液态玻璃，列表保持清晰背景。

界面由 SwiftUI / UIKit 渲染，不使用 WebView。平台业务复用最新共享 TypeScript 接口，在 JavaScriptCore 中无界面运行；第三方音源另在 QuickJS 中隔离执行。它不是完全不含 JavaScript 的应用。

Bundle ID 为 `top.imsyy.splayer-next.native`，可与旧 Tauri 应用并存。登录、曲库和设置独立保存，不自动读取旧应用沙盒。

### 已接通

- 网易云、QQ 音乐、酷狗搜索，网易云推荐歌单、每日推荐和私人 FM，在线曲目解析与 AVPlayer 播放
- 三平台二维码登录界面、登录状态检查和 Keychain 保存；每日推荐、云盘等需要对应平台账号
- 本地文件导入、AVFoundation 元数据与封面提取、艺术家/专辑/文件夹浏览
- 喜欢、最近播放、持久播放队列和进度；重启恢复不自动播放
- 本地歌单创建、加歌、移除和删除，推荐歌单收藏；这些收藏不自动同步到平台账号
- 网易云云盘分页浏览与播放，不包含上传
- 队列重排、顺序/循环/随机、锁屏媒体控制、音频中断处理、耳机断开暂停、系统音量和 AirPlay
- 在线网易云 LRC/YRC、QQ LRC/QRC、酷狗 LRC/KRC 与翻译；逐字数据使用真实毫秒时间戳扫亮，普通 LRC 逐行显示；导入本地 UTF-8 LRC
- 歌词点击跳转，手动浏览后恢复跟随；横屏封面/控制在左、歌词在右，竖屏切换封面/歌词
- 浅色/深色/系统主题；iOS 26+ 系统玻璃，旧系统使用原生材质；减少动态效果时停用连续背景动画

### 自定义源怎么用

进入“设置 → 插件管理”，通过 HTTPS 地址或本地文件导入。新插件默认关闭；查看声明的权限后启用。具备独立搜索能力的插件会提供自己的搜索入口。普通音源为平台搜索得到的曲目解析播放地址。

插件可按授权使用网络、播放控制、曲库、平台接口和界面通知。关闭权限或插件会停止对应运行实例及请求。平台接口复用已登录状态，但返回插件之前过滤凭据，不允许插件覆盖认证请求字段。插件无法直接访问文件系统、宿主对象或 Keychain。

QuickJS-NG 固定为 **0.17.0**，源码和许可证保存在 `Sources/CQuickJS/vendor`。不编译其系统文件/进程模块，不使用 JIT。单实例堆内存 64 MiB、计算片段 2 秒上限；网络、消息、持久存储和请求数量均有上限。未知来源插件仍应先审查，启用即授予所勾选能力。

## 编译与测试

需要 macOS、Xcode、Node/pnpm 和 XcodeGen。仓库根目录执行：

```sh
pnpm install --frozen-lockfile
bash src-tauri/ios-native/scripts/prepare.sh
cd src-tauri/ios-native
xcodegen generate
swift test
xcodebuild -project SPlayerNative.xcodeproj -scheme SPlayerNative \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build
```

`prepare.sh` 从共享 SiriRuntime 和业务入口生成本地资源，不要手改生成副本。修改共享接口或 runtime 后重新执行。

模拟器 UI 测试须使用 Xcode 生成的模拟器签名，不能只在构建后手动补签：

```sh
xcodebuild -project SPlayerNative.xcodeproj -scheme SPlayerNative \
  -destination 'platform=iOS Simulator,id=<iPad UDID>' \
  -derivedDataPath build/simulator -resultBundlePath build/NativeUITests.xcresult \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -collect-test-diagnostics never \
  -only-testing:SPlayerNativeUITests/NativeAppTests test
```

`NativeAppTests` 验证横竖屏导航、中文搜索、导入取消/重开、本地真实播放和页面无 WebView。`NativeRefreshTests` 依赖外网以及安装的旧应用，按单个测试选择执行；它用于原版截图对照和真实平台播放，不放入离线回归要求。

Swift 单元测试覆盖曲库原文件保护、持久队列/歌单、歌词时间、取消竞态和插件权限关闭/超时。共享宿主校验测试位于 `src/mobile/native/pluginHost.spec.ts`。

真实第三方音源测试需显式提供已经审查的脚本路径，默认跳过：

```sh
NATIVE_REAL_PLUGIN_PATH=/absolute/path/source.js \
  swift test --filter NativePluginTests/testRealCustomSourceWhenExplicitlyProvided
```

GitHub Actions `.github/workflows/ios-native-ui.yml` 构建独立应用、运行测试并打包未签名 IPA。IPA 必须使用有效证书签名后才能安装；模拟器构建不等于真机签名或上架验证。

## 与 B 版的视觉差异

已用同一台 iPad 模拟器的同尺寸横竖屏截图检查侧栏、首页、搜索、控制栏和完整播放器。当前保留内容结构，采用 iOS 系统字体与黑白主题；原版自定义主题色、字体以及部分设置布局仍有差异，不宣称逐像素一致。系统玻璃导航与 AMLL 风格全屏播放器是本次按用户补充要求采用的新方向。

首页统计显示本地歌曲、喜欢和最近听过的数量，尚未迁移原版按时间段累计的收听时长统计。

## 尚未迁移与设备验收

以下能力仍需后续实现：Subsonic/Jellyfin/Emby 媒体服务器、听歌识曲、下载管理和歌曲磁盘缓存、云盘上传、TTML 导入、歌词画中画、Siri、均衡器、多语言切换、旧应用数据迁移。原生 AVPlayer 的格式支持与原 AudioStreaming/桌面引擎可能不同。

三平台二维码流程已有代码，但实际扫码授权需要账号持有人完成，不能用二维码生成测试代替登录验收。真机还需验证后台长时间播放、来电恢复、蓝牙/有线耳机、AirPlay、实际音频输出和内存/耗电。当前版本可以作为独立原生版本试用，尚不能替代旧应用的全部功能。
