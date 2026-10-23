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
        .library(
            name: "VoiceTypeSystem",
            targets: ["VoiceTypeSystem"]
        ),
        .executable(
            name: "VoiceType",
            targets: ["VoiceType"]
        ),
    ],
    targets: [
        // Pure Swift: reducer, coordinator, fakes, deterministic helpers. No system frameworks.
        .target(
            name: "VoiceTypeCore"
        ),
        // Live adapters: AVAudioEngine, Speech, Accessibility, NSPasteboard, NSEvent monitors.
        .target(
            name: "VoiceTypeSystem",
            dependencies: ["VoiceTypeCore"]
        ),
        .executableTarget(
            name: "VoiceType",
            dependencies: ["VoiceTypeCore", "VoiceTypeSystem"],
            path: "Sources/VoiceTypeApp"
        ),
        .testTarget(
            name: "VoiceTypeCoreTests",
            dependencies: ["VoiceTypeCore"]
        ),
        .testTarget(
            name: "VoiceTypeSystemTests",
            dependencies: ["VoiceTypeCore", "VoiceTypeSystem"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
