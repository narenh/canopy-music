// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CanopyMusicKit",
    platforms: [.iOS(.v26), .macOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "CanopyMusicCore", targets: ["CanopyMusicCore"]),
        .library(name: "CanopyMusicServer", targets: ["CanopyMusicServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.20.0"),
    ],
    targets: [
        .target(name: "CanopyMusicCore"),
        .target(
            name: "CanopyMusicServer",
            dependencies: ["CanopyMusicCore", .product(name: "FlyingFox", package: "FlyingFox")],
            resources: [.copy("Web")]
        ),
        .executableTarget(name: "CanopyMusicDevServer", dependencies: ["CanopyMusicCore", "CanopyMusicServer", .product(name: "FlyingFox", package: "FlyingFox")]),
        .testTarget(name: "CanopyMusicCoreTests", dependencies: ["CanopyMusicCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CanopyMusicServerTests", dependencies: ["CanopyMusicCore", "CanopyMusicServer"]),
    ]
)
