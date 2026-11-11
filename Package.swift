// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Vlocka",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Vlocka", path: "Sources/Vlocka")
    ]
)
