// swift-tools-version:5.3
import PackageDescription

let package = Package(
  name: "DirectoryAccess",
  platforms: [.iOS(.v13), .macOS(.v10_13)],
  products: [.library(name: "DirectoryAccess", targets: ["DirectoryAccess"])],
  targets: [.target(name: "DirectoryAccess")]
)
