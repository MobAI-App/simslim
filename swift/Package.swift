// swift-tools-version:6.0
import PackageDescription

// No third-party packages, ever. `scripts/verify-deps.sh` fails the check if
// the package declares one.
let package = Package(
  name: "simslim",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "simslim", targets: ["simslim"])
  ],
  dependencies: [],
  targets: [
    // All logic. Never writes to stdout.
    .target(name: "SimSlimKit"),
    // Argument parsing and printing, with injected output and command runner so
    // every command is testable without a terminal or a simulator.
    .target(name: "SimSlimCLI", dependencies: ["SimSlimKit"]),
    // main.swift only.
    .executableTarget(name: "simslim", dependencies: ["SimSlimCLI", "SimSlimKit"]),
    // Test-only helpers (a fake simulator host). Not a dependency of any product.
    .target(name: "TestSupport", dependencies: ["SimSlimKit"], path: "Tests/TestSupport"),
    .testTarget(name: "SimSlimKitTests", dependencies: ["SimSlimKit", "TestSupport"]),
    .testTarget(
      name: "SimSlimCLITests", dependencies: ["SimSlimCLI", "SimSlimKit", "TestSupport"]),
  ],
  swiftLanguageModes: [.v5]
)
