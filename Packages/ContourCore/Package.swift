// swift-tools-version: 6.2
// Contour — GT iOS Club
//
// ContourCore is THE CONTRACT. It depends on nothing, by design and forever.
// If you are about to add a `dependencies:` entry to this file, stop and talk
// to all three teams' leads first. See ../../README.md.

import PackageDescription

let package = Package(
    name: "ContourCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ContourCore", targets: ["ContourCore"])
    ],
    dependencies: [
        // INTENTIONALLY EMPTY. ContourCore depends on nothing.
    ],
    targets: [
        .target(name: "ContourCore"),
        .testTarget(name: "ContourCoreTests", dependencies: ["ContourCore"]),
    ]
)
