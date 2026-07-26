// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WegaMacUpdater",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "WegaMacUpdater", targets: ["WegaMacUpdater"]),
        .executable(name: "WegaAskpass", targets: ["WegaAskpass"]),
        .executable(name: "WegaSudoShim", targets: ["WegaSudoShim"]),
        .library(name: "MacUpdaterCore", targets: ["MacUpdaterCore"]),
    ],
    targets: [
        // SEC-10: minimal contract + helper-security module. Holds ONLY the
        // shared XPC contract and the root-side validation the privileged daemon
        // needs (code-signature verification, PAM writer, fixed system paths), so
        // the root process links this instead of the full MacUpdaterCore (HTTP,
        // parsers, UI helpers) — shrinking the privileged attack surface.
        .target(
            name: "WegaHelperKit"
        ),
        .target(
            name: "MacUpdaterCore",
            dependencies: ["WegaHelperKit"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "WegaMacUpdater",
            dependencies: ["MacUpdaterCore"],
            path: "Sources/MacUpdater"
        ),
        // FEAT-01: privileged daemon, embedded in the app bundle and registered
        // via SMAppService. The launchd plist is excluded from SPM resource
        // handling (build-pkg.sh copies it into Contents/Library/LaunchDaemons/).
        .executableTarget(
            name: "WegaPrivilegedHelper",
            dependencies: ["WegaHelperKit"],
            path: "Sources/WegaPrivilegedHelper",
            exclude: ["com.wega.WegaMacUpdater.helper.plist"]
        ),
        .executableTarget(
            name: "WegaAskpass",
            path: "Sources/WegaAskpass"
        ),
        .executableTarget(
            name: "WegaSudoShim",
            dependencies: ["MacUpdaterCore"],
            path: "Sources/WegaSudoShim"
        ),
        .testTarget(
            name: "MacUpdaterTests",
            dependencies: ["MacUpdaterCore", "WegaHelperKit"],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "MacUpdaterUITests",
            dependencies: ["WegaMacUpdater"]
        )
    ]
)
