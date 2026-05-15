// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WegaMacUpdater",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WegaMacUpdater", targets: ["WegaMacUpdater"]),
        .library(name: "MacUpdaterCore", targets: ["MacUpdaterCore"]),
    ],
    targets: [
        .target(
            name: "MacUpdaterCore"
        ),
        .executableTarget(
            name: "WegaMacUpdater",
            dependencies: ["MacUpdaterCore"],
            path: "Sources/MacUpdater"
        ),
        .testTarget(
            name: "MacUpdaterTests",
            dependencies: ["MacUpdaterCore"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
