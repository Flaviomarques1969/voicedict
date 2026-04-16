// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ditado",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Ditado",
            path: "Sources/Ditado",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
