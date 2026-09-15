// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftTorrent",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18)
    ],
    products: [
        .library(name: "SwiftTorrent", targets: ["SwiftTorrent"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftTorrent",
            dependencies: []
        ),
        .testTarget(
            name: "SwiftTorrentTests",
            dependencies: ["SwiftTorrent"]
        ),
    ]
)
