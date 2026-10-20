# iOS 上游同步记录（2026-09-20）

同步来源：[SPlayer-Dev/SPlayer-Next dev](https://github.com/SPlayer-Dev/SPlayer-Next/commits/dev/)。本次将上游 `dev` 合并到 iOS `main`，并保留 iOS/Tauri 原生层与移动端桥接。

## 已同步

- AMLL 0.6.0 相关歌词与背景渲染共享代码中可用于 iOS 的部分。
- 歌词 TTML 下载、歌词选择、播放恢复、插件 shim、网络请求和播放器 IPC 的通用修复。
- 共享类型、依赖锁文件、构建脚本、CI 辅助脚本及上游测试。

## iOS 保留与禁用

- 保留 `src-tauri/`、Siri、AirPlay、歌词画中画、移动端缓存、文件权限和移动端媒体桥接；上游对这些目录的删除不采纳。
- 禁用桌面独立输出设备音量、PipeWire/Windows 缩略图、Electron 桌面插件宿主和不支持的 AMLL `IsolationRenderer`。
- 保留 iOS 现有歌词引擎、预设字段和播放器状态类型，避免桌面专属设置进入移动端构建。

## 验证

- `tsc --noEmit -p tsconfig.node.json --composite false`
- `vue-tsc --noEmit -p tsconfig.web.json --composite false`
- 移动端原生目录未被上游删除或覆盖。
