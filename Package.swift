// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PXLmpeg", platforms: [.macOS(.v15)],
  products: [
    .library(name: "PXLMedia", targets: ["PXLMedia"]),
    .library(name: "PXLmpeg", targets: ["PXLmpeg"]),
    .library(name: "PXLPlayback", targets: ["PXLPlayback"]),
    .library(name: "PXLAnalysis", targets: ["PXLAnalysis"]),
    .executable(name: "pxl-search", targets: ["PXLSearchCLI"]),
    .executable(name: "pxlmpeg", targets: ["PXLmpegCLI"]),
    .executable(name: "pxl-player", targets: ["PXLPlayer"]),
    .executable(name: "pxl-validation", targets: ["PXLValidation"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "PXLMedia"),
    .target(name: "PXLAnalysis", dependencies: ["PXLMedia", "PXLAppleMedia"]),
    .executableTarget(name: "PXLSearchCLI", dependencies: ["PXLAnalysis", "PXLMedia"]),
    .testTarget(name: "PXLAnalysisTests", dependencies: ["PXLAnalysis", "PXLTestSupport", "PXLAppleMedia"]),
    .executableTarget(name: "PXLPlayer", dependencies: ["PXLPlayback", "PXLMedia"]),
    .target(name: "PXLPlayback", dependencies: ["PXLMedia", "PXLAppleMedia"]),
    .testTarget(name: "PXLPlaybackTests", dependencies: ["PXLPlayback", "PXLTestSupport"]),
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
