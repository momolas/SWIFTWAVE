// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TorrentKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18)
    ],
    products: [
        .library(name: "TorrentKit", targets: ["TorrentKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TorrentKit",
            path: "Sources/SwiftTorrent"
        ),
        .testTarget(
            name: "TorrentKitTests",
            dependencies: ["TorrentKit"],
            path: "Tests/SwiftTorrentTests"
        ),
    ]
)
