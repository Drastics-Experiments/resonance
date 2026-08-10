// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Resonance",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Resonance", targets: ["Resonance"])],
    dependencies: [
        .package(url: "https://github.com/clerk/clerk-ios", from: "1.3.6"),
    ],
    targets: [
        .executableTarget(
            name: "Resonance",
            dependencies: [
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ClerkKitUI", package: "clerk-ios"),
            ],
            path: "Sources/Resonance"
        ),
        .testTarget(
            name: "ResonanceTests",
            dependencies: ["Resonance"],
            path: "Tests/ResonanceTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
