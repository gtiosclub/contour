// swift-tools-version: 6.2
// Contour — Tracking / Spatial
//
// DEPENDENCY RULE: this package may depend on ContourCore and nothing else.
// Not on SurfaceUnderstanding, not on ContourFeedback, not on ContourUI,
// not on ContourMocks. Scripts/check-dependencies.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "Tracking",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Tracking", targets: ["Tracking"])
    ],
    dependencies: [
        .package(path: "../ContourCore")
    ],
    targets: [
        .target(
            name: "Tracking",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(name: "TrackingTests", dependencies: ["Tracking"]),
    ]
)
