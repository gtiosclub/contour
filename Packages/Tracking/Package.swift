// swift-tools-version: 6.4
// Contour — Tracking / Spatial
//
// DEPENDENCY RULE: this package's SOURCE target may depend on ContourCore and
// nothing else. Not on SurfaceUnderstanding, not on ContourFeedback, not on
// ContourUI. Its TEST target may also depend on ContourMocks, so tests can run
// against the shared deterministic fakes.
// The one remote exception is OpenCV, pinned exactly, used only by the C++
// ContourFeatureMatcher target behind a C interface (#81). OpenCV types never
// appear in Swift or ContourCore. License: Apache 2.0, see THIRD_PARTY_NOTICES.md.
// Scripts/check-dependencies.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "Tracking",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "Tracking", targets: ["Tracking"])
    ],
    dependencies: [
        .package(path: "../ContourCore"),
        .package(path: "../ContourMocks"),
        .package(url: "https://github.com/yeatse/opencv-spm.git", exact: "4.13.0"),
    ],
    targets: [
        .target(
            name: "Tracking",
            dependencies: [
                .product(name: "ContourCore", package: "ContourCore"),
                "ContourFeatureMatcher",
            ]
        ),
        .target(
            name: "ContourFeatureMatcher",
            dependencies: [.product(name: "OpenCV", package: "opencv-spm")]
        ),
        .testTarget(
            name: "TrackingTests",
            dependencies: [
                "Tracking",
                "ContourFeatureMatcher",
                .product(name: "ContourMocks", package: "ContourMocks"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
