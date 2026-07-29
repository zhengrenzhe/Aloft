// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aloft",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Aloft", targets: ["AloftApp"])],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm",
            exact: "1.15.0"
        ),
    ],
    targets: [
        .target(
            name: "AloftProcess",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "AloftApp",
            dependencies: [
                "AloftProcess",
                .product(
                    name: "SwiftTerm",
                    package: "SwiftTerm"
                ),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "AloftAppTests",
            dependencies: [
                "AloftApp",
                .product(
                    name: "SwiftTerm",
                    package: "SwiftTerm"
                ),
            ],
            resources: [
                .copy("Fixtures/Unicode17/GraphemeBreakTest.txt"),
                .copy("Fixtures/Unicode17/NormalizationTest.txt"),
            ]
        ),
        .testTarget(
            name: "AloftProcessTests",
            dependencies: ["AloftApp", "AloftProcess"]
        ),
        .testTarget(
            name: "AloftPerformanceTests",
            dependencies: [
                "AloftApp",
                .product(
                    name: "SwiftTerm",
                    package: "SwiftTerm"
                ),
            ]
        ),
    ]
)
