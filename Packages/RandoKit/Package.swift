// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RandoKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RandoKit", targets: ["RandoKit"])
    ],
    targets: [
        .target(name: "RandoKit"),
        .testTarget(name: "RandoKitTests", dependencies: ["RandoKit"]),
    ]
)
