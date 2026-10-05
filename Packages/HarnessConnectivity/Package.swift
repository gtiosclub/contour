// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HarnessConnectivity",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [.library(name: "HarnessConnectivity", targets: ["HarnessConnectivity"])],
    dependencies: [.package(path: "../ContourCore")],
    targets: [
        .target(name: "HarnessConnectivity", dependencies: ["ContourCore"]),
        .testTarget(name: "HarnessConnectivityTests", dependencies: ["HarnessConnectivity", "ContourCore"])
    ]
)
