// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceType",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "VoiceTypeCore",
            targets: ["VoiceTypeCore"]
        ),
        .executable(
            name: "VoiceType",
            targets: ["VoiceType"]
        ),
    ],
    targets: [
        .target(
            name: "VoiceTypeCore"
        ),
        .executableTarget(
            name: "VoiceType",
            dependencies: ["VoiceTypeCore"],
            path: "Sources/VoiceTypeApp"
        ),
        .testTarget(
            name: "VoiceTypeCoreTests",
            dependencies: ["VoiceTypeCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
