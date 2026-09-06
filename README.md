<div align="center">

<img alt="SPlayer-Next logo" width="120" height="120" src="public/icons/favicon.png" />

# SPlayer Next · iOS / iPadOS

适用于 iPhone 和 iPad 的 [SPlayer Next](https://github.com/SPlayer-Dev/SPlayer-Next) 移动适配版（基于 Tauri）。

[下载 IPA](https://github.com/q3cc/SPlayer-Next-ios/releases/latest) · [反馈问题](https://github.com/q3cc/SPlayer-Next-ios/issues) · [上游项目](https://github.com/SPlayer-Dev/SPlayer-Next)

</div>

> **提示**：本项目为第三方移植版，非官方构建。桌面版本请前往原项目下载。

---

## 特性

- **多端适配**：支持 iPhone 紧凑布局与 iPad 横屏大屏视图，适配动态岛、刘海屏及前台调度（Stage Manager）。
- **在线曲库**：支持网易云扫码登录、歌单浏览与每日推荐，本地持久化保存登录状态。
- **本地音乐**：支持从“文件”App 批量导入本地音频至应用隔离沙盒。
- **后台与控制中心**：支持锁屏封面展示、后台音频播放与系统级多媒体控制。
- **原生音效**：10 段均衡器、预设、前级增益与升降调实时生效；在播放器“更多 → 均衡器”中调整。
- **歌词体验**：
  - **画中画小窗歌词**：支持单/双行、逐字高亮、音译与翻译显示，支持大小与颜色自定义。
  - **系统标题歌词**：支持将实时歌词临时映射为锁屏/控制中心的媒体标题。

---

## 安装与使用

系统要求：**iOS / iPadOS 16.0+**

1. **获取安装包**：前往 [Releases](https://github.com/q3cc/SPlayer-Next-ios/releases/latest) 下载最新的未签名 `.ipa`（开发版请至 [Actions](https://github.com/q3cc/SPlayer-Next-ios/actions/workflows/ios-unsigned.yml) 下载构建产物）。
2. **签名安装**：使用个人证书或签名工具（如 TrollStore、AltStore、SideStore、牛蛙助手等）自签名并安装。
3. **启用歌词**：在应用内进入“设置 → 桌面歌词”开启悬浮小窗歌词。
4. **配置 Siri**：在“设置 → Siri”开启语音控制，选择音乐来源、搜索范围和选歌确认方式。可尝试“用 SPlayer 播放晴天”，或在快捷指令中添加 SPlayer 的播放、暂停和切歌操作。此功能仍需实机验证。

---

## 常见问题

**Q: 重签后 Siri 不可用？**  
签名证书及描述文件需要支持并保留 `com.apple.developer.siri` 能力。未签名 IPA 的构建检查不能替代重签和真机验证；系统是否要求解锁也由 iOS 决定。本地歌曲按歌手搜索依赖文件中的音频标签，旧导入文件可重新扫描补充标签。

为避免缺失权限导致启动崩溃，当前通过 Security 的 `SecTask` 符号只读检查自身签名。这些符号未列入 iOS 的公开 SDK，若系统不再提供，Siri 会停用，不影响其他功能；本项目的自签名 IPA 不等同于 App Store 可上架版本。

**Q: 本地歌曲导入后，原文件会受影响吗？**  
不会。音乐文件会被复制进应用的沙盒目录（`Documents/Imported Music`），与原文件完全隔离，删除应用或原文件互不影响。

**Q: 遇到登录、闪退或播放异常，如何提取日志？**

1. 进入“设置 → 通用 → 调试”开启“日志记录”，随后复现问题。
2. 打开 iOS 自带的“文件”App，依次进入：`我的 iPhone/iPad → SPlayer Next → logs`。
3. 导出对应时间的 `.log` 文件，并在 [提交 Issue](https://github.com/q3cc/SPlayer-Next-ios/issues) 时附上日志、机型与系统版本。

---

## 本地构建

环境依赖：macOS、Xcode、Rust (iOS Target)、Node.js >= 22.19.0、pnpm。

```bash
git clone [https://github.com/q3cc/SPlayer-Next-ios.git](https://github.com/q3cc/SPlayer-Next-ios.git)
cd SPlayer-Next-ios
git switch main

pnpm install --frozen-lockfile
pnpm ios:init
pnpm ios:build --ci --no-sign

```

- 仅编译前端：`pnpm mobile:build`
- 本地联机调试：`pnpm ios:dev`
- 详见完整的 [iOS 构建指南](https://www.google.com/search?q=docs/ios-unsigned.md)。

---

## 开源协议与致谢

- 本项目沿用上游项目的 **AGPL-3.0** 开源许可协议。
- 感谢 [SPlayer-Dev](https://github.com/SPlayer-Dev) 及所有上游贡献者。
- 核心依赖：[applemusic-like-lyrics](https://github.com/Steve-xmh/applemusic-like-lyrics)、[NeteaseCloudMusicApiEnhanced](https://github.com/neteasecloudmusicapienhanced/api-enhanced)、[Tauri](https://github.com/tauri-apps/tauri)。
- 原生音频播放复用 [AudioStreaming](https://github.com/dimitris-c/AudioStreaming)，均衡器和升降调使用系统音频节点。
- 鸣谢社区：[LinuxDO](https://linux.do/)。
