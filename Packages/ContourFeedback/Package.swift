// swift-tools-version: 6.2
// Contour — Experience
//
// DEPENDENCY RULE: this package may depend on ContourCore and nothing else.
// Not on SurfaceUnderstanding, not on Tracking, not on ContourUI,
// not on ContourMocks. Scripts/check-dependencies.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "ContourFeedback",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ContourFeedback", targets: ["ContourFeedback"])
    ],
    dependencies: [
        .package(path: "../ContourCore")
    ],
    targets: [
        .target(
            name: "ContourFeedback",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(name: "ContourFeedbackTests", dependencies: ["ContourFeedback"]),
    ]
)
