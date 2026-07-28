// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aloft",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Aloft", targets: ["AloftApp"])],
    targets: [
        .target(
            name: "AloftProcess",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "AloftApp",
            dependencies: ["AloftProcess"]
        ),
        .testTarget(
            name: "AloftAppTests",
            dependencies: ["AloftApp"]
        ),
        .testTarget(
            name: "AloftProcessTests",
            dependencies: ["AloftApp", "AloftProcess"]
        ),
    ]
)
