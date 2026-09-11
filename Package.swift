// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "trajectory-eval-gate-kit",
    // Only platforms CI actually builds are declared. Linux needs no declaration
    // (the Linux job builds the core target); the demo app's CI builds for
    // `generic/platform=iOS Simulator`. watchOS/tvOS are deliberately absent —
    // declaring a platform nothing compiles for is a claim without evidence.
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "TrajectoryEvalGate", targets: ["TrajectoryEvalGate"]),
        .library(name: "TrajectoryEvalGateUI", targets: ["TrajectoryEvalGateUI"])
    ],
    targets: [
        .target(name: "TrajectoryEvalGate"),
        .target(name: "TrajectoryEvalGateUI", dependencies: ["TrajectoryEvalGate"]),
        .testTarget(name: "TrajectoryEvalGateTests", dependencies: ["TrajectoryEvalGate"])
    ]
)
