// SEC-10: `WegaHelperKit` was carved out of `MacUpdaterCore` so the root daemon
// links only the contract + validation it needs (see the target comment in
// Package.swift). Re-export it here so every existing `import MacUpdaterCore`
// call site keeps seeing the relocated public types (`WegaHelper`,
// `WegaPrivilegedOps`, `SystemPaths`, `AppMetadata`, `CodeSignatureVerifier`,
// `TouchIDSudoConfigurator`, …) without touching dozens of files.
@_exported import WegaHelperKit
