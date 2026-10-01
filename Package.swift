// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "git-credential-code-storage",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(name: "git-credential-code-storage")
  ]
)
