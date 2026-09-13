// swift-tools-version: 6.2
// Contour — shared fakes
//
// DEPENDENCY RULE: ContourMocks depends on ContourCore and nothing else.
// It implements all three protocols without importing any team's package —
// that is what makes it safe for all four teams to depend on at once.
// Scripts/check-dependencies.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "ContourMocks",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ContourMocks", targets: ["ContourMocks"])
    ],
    dependencies: [
        .package(path: "../ContourCore")
    ],
    targets: [
        .target(
            name: "ContourMocks",
            dependencies: [.product(name: "ContourCore", package: "ContourCore")]
        ),
        .testTarget(name: "ContourMocksTests", dependencies: ["ContourMocks"]),
    ]
)
