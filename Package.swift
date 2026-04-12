// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceDict",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "VoiceDict",
            path: "Sources/VoiceDict",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
