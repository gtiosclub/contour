// swift-tools-version: 6.2
// Contour — Experience
//
// DEPENDENCY RULE: this package may depend on ContourCore and nothing else.
// Not on SurfaceUnderstanding, not on Tracking, not on ContourFeedback,
// not on ContourMocks. Scripts/check-dependencies.sh enforces this in CI.
//
// Yes, that means you cannot call Surface Understanding's detector from a view,
// even though Experience owns ContourFeedback too. The app target
// wires the two together and hands you the result. That is the point.

import PackageDescription

let package = Package(
    name: "ContourUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ContourUI", targets: ["ContourUI"])
    ],
    dependencies: [
        .package(path: "../ContourCore")
    ],
    targets: [
        .target(
            name: "ContourUI",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(name: "ContourUITests", dependencies: ["ContourUI"]),
    ]
)
