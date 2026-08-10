// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Resonance",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Resonance", targets: ["Resonance"])],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Resonance",
            dependencies: [],
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
