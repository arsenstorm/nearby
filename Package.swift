// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NearbyCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NearbyCore", targets: ["NearbyCore"])],
    targets: [
        .target(name: "NearbyCore"),
        .testTarget(name: "NearbyCoreTests", dependencies: ["NearbyCore"]),
    ]
)
