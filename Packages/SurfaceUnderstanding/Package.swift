// swift-tools-version: 6.2
// Contour — Team 1
//
// DEPENDENCY RULE: this package may depend on ContourCore and nothing else.
// Not on Tracking, not on ContourFeedback, not on ContourUI, not on ContourMocks.
// The whole point of the layout is that the four teams cannot block each other.
// Scripts/check-dependencies.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "SurfaceUnderstanding",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SurfaceUnderstanding", targets: ["SurfaceUnderstanding"])
    ],
    dependencies: [
        .package(path: "../ContourCore")
    ],
    targets: [
        .target(
            name: "SurfaceUnderstanding",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(
            name: "SurfaceUnderstandingTests",
            dependencies: ["SurfaceUnderstanding"]
        ),
    ]
)
