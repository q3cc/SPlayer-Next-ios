// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "tauri-plugin-native-audio",
  platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16)],
  products: [.library(name: "tauri-plugin-native-audio", type: .static, targets: ["tauri-plugin-native-audio"])],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api"),
    // 保留原生解码与音效链，并修复 FLAC 变码率音源的精确跳转。
    .package(path: "../../../vendor/AudioStreaming"),
    .package(path: "../../../vendor/DirectoryAccess")
  ],
  targets: [
    .target(name: "SiriAuthorization", path: "AuthorizationBridge", publicHeadersPath: "include"),
    .target(name: "tauri-plugin-native-audio", dependencies: [
      .byName(name: "Tauri"), .byName(name: "SiriAuthorization"),
      .product(name: "AudioStreaming", package: "AudioStreaming"),
      .product(name: "DirectoryAccess", package: "DirectoryAccess")
    ], path: "Sources", exclude: ["Resources"])
  ]
)
