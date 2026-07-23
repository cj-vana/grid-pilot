// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GridPilot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GridPilot",
            path: "Sources/GridPilot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GridPilotTests",
            dependencies: ["GridPilot"],
            path: "Tests/GridPilotTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
