// swift-tools-version: 6.2
// Contour — Experience
//
// DEPENDENCY RULE: this package's SOURCE target may depend on ContourCore and
// nothing else. Not on SurfaceUnderstanding, not on Tracking, not on ContourUI.
// Its TEST target may also depend on ContourMocks, so tests can run against the
// shared deterministic fakes.
// Experience also owns ContourUI and ContourMocks, but they stay separate
// packages: the boundary is what keeps the app's wiring in ContourApp.
// Scripts/check-dependencies.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "ContourFeedback",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ContourFeedback", targets: ["ContourFeedback"])
    ],
    dependencies: [
        .package(path: "../ContourCore"),
        .package(path: "../ContourMocks"),
    ],
    targets: [
        .target(
            name: "ContourFeedback",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(
            name: "ContourFeedbackTests",
            dependencies: [
                "ContourFeedback",
                .product(name: "ContourMocks", package: "ContourMocks"),
            ]
        ),
    ]
)
