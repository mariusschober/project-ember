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
    .testTarget(name: "ProjectEmberTests", dependencies: ["ProjectEmber", "EmberCore"]),
  ],
  swiftLanguageModes: [.v6]
)
