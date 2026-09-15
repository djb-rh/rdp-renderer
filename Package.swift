// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "rdp-renderer",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "RDPKit", targets: ["RDPKit"]),
        .executable(name: "rdpview", targets: ["rdpview"]),
    ],
    targets: [
        .target(name: "RDPKit"),
        .executableTarget(name: "rdpview", dependencies: ["RDPKit"]),
    ]
)
