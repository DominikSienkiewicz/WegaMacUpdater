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
        .library(name: "MacUpdaterHelperClient", targets: ["MacUpdaterHelperClient"]),
        .executable(name: "WegaMacUpdaterPrivilegedHelper", targets: ["WegaMacUpdaterPrivilegedHelper"])
    ],
    targets: [
        .target(
            name: "MacUpdaterCore"
        ),
        .target(
            name: "MacUpdaterHelperClient",
            dependencies: ["MacUpdaterCore"]
        ),
        .executableTarget(
            name: "WegaMacUpdater",
            dependencies: [
                "MacUpdaterCore",
                "MacUpdaterHelperClient"
            ],
            path: "Sources/MacUpdater"
        ),
        .executableTarget(
            name: "WegaMacUpdaterPrivilegedHelper",
            dependencies: ["MacUpdaterCore"],
            path: "Sources/MacUpdaterPrivilegedHelper"
        ),
        .testTarget(
            name: "MacUpdaterTests",
            dependencies: [
                "MacUpdaterCore",
                "MacUpdaterHelperClient"
            ],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
