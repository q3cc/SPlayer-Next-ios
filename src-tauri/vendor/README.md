# 移动端目录选择补丁

源包为官方 `tauri-plugin-dialog 2.7.3`，保留原许可证。
下载地址：https://static.crates.io/crates/tauri-plugin-dialog/tauri-plugin-dialog-2.7.3.crate
SHA-256：`61854a36651aa48381e5e209f69a01273b77f3f9f91f0c430b1b98d33bd47229`。

原包的 `open({ directory: true })` 在移动端直接返回 `FolderPickerNotImplemented`。
补丁仍使用同一个 JS/Rust 接口与 UIKit 文件选择器，只补齐 iOS 的 `UTType.folder` 模式、
递归访问范围与错误返回。Android 和桌面行为不变。

应用使用 `fileAccessMode: "scoped"`：用户选择的目录由 iOS 授予安全范围访问权限，应用保存安全书签，
冷启动时恢复授权后直接扫描和播放原目录，不复制歌曲，也不会修改原目录。目录被移除或授权失效时，曲库保留记录并提示重新授权。
`DirectoryAccess` 同时向扫描、元数据读取和原生播放器提供访问租约，避免后台播放丢失权限。
