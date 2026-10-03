// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ProjectEmber",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "EmberCore", targets: ["EmberCore"]),
    .executable(name: "EmberCoreChecks", targets: ["EmberCoreChecks"]),
    .executable(name: "ProjectEmber", targets: ["ProjectEmber"]),
  ],
  targets: [
    .target(name: "EmberCore"),
    .executableTarget(
      name: "ProjectEmber",
      dependencies: ["EmberCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ColorSync"),
        .linkedFramework("CoreLocation"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .executableTarget(name: "EmberCoreChecks", dependencies: ["EmberCore"]),
    .testTarget(name: "EmberCoreTests", dependencies: ["EmberCore"]),
    // Drives DisplayCoordinator through injected fakes: the shipped
    // orchestration is otherwise only reachable by mutating real displays.
    //
    // Note: because it imports the executable target, `swift build --build-tests
    // -c release` needs testability enabled explicitly —
    //   swift build --build-tests -c release -Xswiftc -enable-testing
    // `swift test` and `swift test -c release` both work as-is, and those are the
    // commands the release scripts and CI use.
    .testTarget(name: "ProjectEmberTests", dependencies: ["ProjectEmber", "EmberCore"]),
  ],
  swiftLanguageModes: [.v6]
)
