// swift-tools-version: 6.2
// Contour — Surface Understanding
//
// DEPENDENCY RULE: this package's SOURCE target may depend on ContourCore and
// nothing else. Not on Tracking, not on ContourFeedback, not on ContourUI.
// Its TEST target may also depend on ContourMocks, so tests can run against the
// shared deterministic fakes.
// The whole point of the layout is that the three teams cannot block each other.
// Scripts/check-dependencies.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "SurfaceUnderstanding",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SurfaceUnderstanding", targets: ["SurfaceUnderstanding"])
    ],
    dependencies: [
        .package(path: "../ContourCore"),
        .package(path: "../ContourMocks"),
    ],
    targets: [
        .target(
            name: "SurfaceUnderstanding",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(
            name: "SurfaceUnderstandingTests",
            dependencies: [
                "SurfaceUnderstanding",
                .product(name: "ContourMocks", package: "ContourMocks"),
            ]
        ),
    ]
)
