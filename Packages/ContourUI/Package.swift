// swift-tools-version: 6.2
// Contour — Experience
//
// DEPENDENCY RULE: this package's SOURCE target may depend on ContourCore and
// nothing else. Not on SurfaceUnderstanding, not on Tracking, not on
// ContourFeedback. Its TEST target may also depend on ContourMocks, so tests can
// run against the shared deterministic fakes.
//
// Yes, that means you cannot call Surface Understanding's detector from a view,
// even though Experience owns ContourFeedback too. The app target wires the
// packages together and hands you the result. That is the point.

import PackageDescription

let package = Package(
    name: "ContourUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ContourUI", targets: ["ContourUI"])
    ],
    dependencies: [
        .package(path: "../ContourCore"),
        .package(path: "../ContourMocks"),
    ],
    targets: [
        .target(
            name: "ContourUI",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(
            name: "ContourUITests",
            dependencies: [
                "ContourUI",
                .product(name: "ContourMocks", package: "ContourMocks"),
            ]
        ),
    ]
)
