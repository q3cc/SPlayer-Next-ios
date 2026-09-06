// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "tauri-plugin-native-audio",
  platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16)],
  products: [.library(name: "tauri-plugin-native-audio", type: .static, targets: ["tauri-plugin-native-audio"])],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api"),
    // 1.3.0 支持系统 MP3/AAC/FLAC 解码，不依赖需要额外嵌入 IPA 的动态编解码框架。
    .package(url: "https://github.com/dimitris-c/AudioStreaming.git", revision: "4b8bae96c2e624aa64f6e0ac361ee76a3374a641")
  ],
  targets: [
    .target(name: "SiriAuthorization", path: "AuthorizationBridge", publicHeadersPath: "include"),
    .target(name: "tauri-plugin-native-audio", dependencies: [
      .byName(name: "Tauri"), .byName(name: "SiriAuthorization"),
      .product(name: "AudioStreaming", package: "AudioStreaming")
    ], path: "Sources", exclude: ["Resources"])
  ]
)
