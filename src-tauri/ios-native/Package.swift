// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SPlayerNativeUI",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "SPlayerNativeUI", targets: ["SPlayerNativeUI"])],
    targets: [
        .target(name: "SPlayerNativeUI", resources: [.process("Resources")]),
        .testTarget(name: "SPlayerNativeUITests", dependencies: ["SPlayerNativeUI"]),
    ]
)
