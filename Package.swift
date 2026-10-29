// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WalkingPad",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WalkingPad",
            path: "Sources/WalkingPad",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
