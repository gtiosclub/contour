// swift-tools-version: 6.2
// Contour — Tracking / Spatial
//
// DEPENDENCY RULE: this package's SOURCE target may depend on ContourCore and
// nothing else. Not on SurfaceUnderstanding, not on ContourFeedback, not on
// ContourUI. Its TEST target may also depend on ContourMocks, so tests can run
// against the shared deterministic fakes.
// Scripts/check-dependencies.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "Tracking",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Tracking", targets: ["Tracking"])
    ],
    dependencies: [
        .package(path: "../ContourCore"),
        .package(path: "../ContourMocks"),
    ],
    targets: [
        .target(
            name: "Tracking",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(
            name: "TrackingTests",
            dependencies: [
                "Tracking",
                .product(name: "ContourMocks", package: "ContourMocks"),
            ]
        ),
    ]
)
