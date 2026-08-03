// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LikedSongsFocus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LikedSongsFocus", targets: ["LikedSongsFocus"])],
    targets: [
        .executableTarget(
            name: "LikedSongsFocus",
            path: "Sources/LikedSongsFocus"
        ),
        .testTarget(
            name: "LikedSongsFocusTests",
            dependencies: ["LikedSongsFocus"],
            path: "Tests/LikedSongsFocusTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
