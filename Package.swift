// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "iSnow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iSnow",
            path: "Sources/iSnow",
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))]
        )
    ]
)
