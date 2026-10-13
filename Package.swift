// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PXLmpeg", platforms: [.macOS(.v15)],
  products: [
    .library(name: "PXLMedia", targets: ["PXLMedia"]),
    .library(name: "PXLmpeg", targets: ["PXLmpeg"]),
    .executable(name: "pxlmpeg", targets: ["PXLmpegCLI"]),
    .executable(name: "pxl-validation", targets: ["PXLValidation"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "PXLMedia"),
    .executableTarget(
      name: "PXLValidation",
      dependencies: ["PXLmpeg", "PXLMedia", "PXLAppleMedia", "PXLMetal", "PXLTestSupport"],
      path: "Tools/PXLValidation"),
    .executableTarget(name: "PXLmpegCLI", dependencies: ["PXLmpeg", "PXLMedia"]),
    .testTarget(
      name: "PXLmpegCLITests", dependencies: ["PXLmpegCLI", "PXLTestSupport", "PXLMedia"]),
    .target(name: "PXLmpeg", dependencies: ["PXLMedia", "PXLAppleMedia", "PXLMetal"]),
    .testTarget(
      name: "PXLmpegTests", dependencies: ["PXLmpeg", "PXLTestSupport", "PXLAppleMedia"]),
    .target(name: "PXLAppleMedia", dependencies: ["PXLMedia"]),
    .target(name: "PXLTestSupport", dependencies: ["PXLMedia"], path: "Tests/Support"),
    .testTarget(name: "PXLAppleMediaTests", dependencies: ["PXLAppleMedia", "PXLTestSupport"]),
    .target(
      name: "PXLMetal", dependencies: ["PXLMedia", "PXLAppleMedia"], resources: [.copy("Resources")]
    ),
    .testTarget(name: "PXLMetalTests", dependencies: ["PXLMetal", "PXLAppleMedia"]),
    .testTarget(name: "PXLMediaTests", dependencies: ["PXLMedia"]),
  ], swiftLanguageModes: [.v6]
)
