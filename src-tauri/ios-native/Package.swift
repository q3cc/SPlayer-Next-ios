// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "SPlayerNativeUI",
  platforms: [.iOS(.v16), .macOS(.v14)],
  products: [.library(name: "SPlayerNativeUI", targets: ["SPlayerNativeUI"])],
  targets: [
    .target(
      name: "CQuickJS", path: "Sources/CQuickJS", exclude: ["vendor/LICENSE"],
      sources: [
        "NativeJS.c", "vendor/quickjs.c", "vendor/dtoa.c", "vendor/libregexp.c",
        "vendor/libunicode.c",
      ], publicHeadersPath: "include", cSettings: [.define("_GNU_SOURCE")],
      linkerSettings: [.linkedFramework("Security")]),
    .target(
      name: "SPlayerNativeUI", dependencies: ["CQuickJS"], resources: [.process("Resources")]),
    .testTarget(name: "SPlayerNativeUITests", dependencies: ["SPlayerNativeUI"]),
  ]
)
