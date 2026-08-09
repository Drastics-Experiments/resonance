// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LikedSongsFocus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LikedSongsFocus", targets: ["LikedSongsFocus"])],
    dependencies: [
        .package(url: "https://github.com/clerk/clerk-ios", from: "1.3.6"),
    ],
    targets: [
        .executableTarget(
            name: "LikedSongsFocus",
            dependencies: [
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ClerkKitUI", package: "clerk-ios"),
            ],
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
