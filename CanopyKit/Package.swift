// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CanopyKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "CanopyCore", targets: ["CanopyCore"]),
        .library(name: "CanopyServer", targets: ["CanopyServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.20.0"),
    ],
    targets: [
        .target(name: "CanopyCore"),
        .target(
            name: "CanopyServer",
            dependencies: ["CanopyCore", .product(name: "FlyingFox", package: "FlyingFox")],
            resources: [.copy("Web")]
        ),
        .executableTarget(name: "CanopyDevServer", dependencies: ["CanopyCore", "CanopyServer"]),
        .testTarget(name: "CanopyCoreTests", dependencies: ["CanopyCore"]),
    ]
)
