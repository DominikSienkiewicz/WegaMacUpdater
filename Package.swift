// swift-tools-version: 6.0

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
            name: "MacUpdaterCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "WegaMacUpdater",
            dependencies: ["MacUpdaterCore"],
            path: "Sources/MacUpdater",
            exclude: ["Info.plist"]
        ),
        // FEAT-01: privileged daemon, embedded in the app bundle and registered
        // via SMAppService. The launchd plist is excluded from SPM resource
        // handling (build-pkg.sh copies it into Contents/Library/LaunchDaemons/).
        .executableTarget(
            name: "WegaPrivilegedHelper",
            dependencies: ["MacUpdaterCore"],
            path: "Sources/WegaPrivilegedHelper",
            exclude: ["com.wega.WegaMacUpdater.helper.plist"]
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
