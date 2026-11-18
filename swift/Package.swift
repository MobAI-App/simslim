// swift-tools-version:6.0
import PackageDescription

// No third-party packages, ever. `scripts/verify-deps.sh` fails the check if
// `dependencies` is anything other than an empty list.
let package = Package(
  name: "simslim",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "simslim", targets: ["simslim"])
  ],
  dependencies: [],
  targets: [
    .target(name: "SimSlimKit"),
    .executableTarget(name: "simslim", dependencies: ["SimSlimKit"]),
    .testTarget(name: "SimSlimKitTests", dependencies: ["SimSlimKit"]),
  ],
  swiftLanguageModes: [.v5]
)
