import Foundation

/// Network condition snapshot for the download gate (FEAT-07). Populate from
/// `NWPathMonitor.currentPath` (`isExpensive` / `isConstrained`).
public struct NetworkCondition: Equatable, Sendable {
    public var isExpensive: Bool    // metered: cellular / personal hotspot
    public var isConstrained: Bool  // Low Data Mode
    public init(isExpensive: Bool, isConstrained: Bool) {
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
    public static let unrestricted = NetworkCondition(isExpensive: false, isConstrained: false)
}

/// Power/thermal snapshot for the download gate (FEAT-07).
public struct PowerCondition: Equatable, Sendable {
    public var onBattery: Bool
    public var batteryFraction: Double?   // 0...1; nil on desktops / unknown
    public var thermalSerious: Bool       // ProcessInfo.thermalState >= .serious
    public init(onBattery: Bool, batteryFraction: Double?, thermalSerious: Bool) {
        self.onBattery = onBattery
        self.batteryFraction = batteryFraction
        self.thermalSerious = thermalSerious
    }
    public static let plugged = PowerCondition(onBattery: false, batteryFraction: nil, thermalSerious: false)
}

/// Decides whether a *large* download proceeds now or is deferred (**FEAT-07 / I-4**).
/// FinOps at the endpoint: don't burn metered data, don't drain a low battery, don't
/// pull gigabytes while thermally throttled. Pure policy → unit-tested; live probing
/// (NWPathMonitor / IOPowerSources) is the caller's job.
public enum DownloadGate {
    public struct Configuration: Equatable, Sendable {
        public static let largeDownloadThresholdMBKey = "wega.downloadGate.largeDownloadThresholdMB"
        public static let lowBatteryThresholdPercentKey = "wega.downloadGate.lowBatteryThresholdPercent"
        public static let unpackedSizeMultiplierKey = "wega.downloadGate.unpackedSizeMultiplier"
        public static let safetyMarginGBKey = "wega.downloadGate.safetyMarginGB"

        public static let defaultLargeDownloadThresholdMB = 200
        public static let defaultLowBatteryThresholdPercent = 20
        public static let defaultUnpackedSizeMultiplier = 2.0
        public static let defaultSafetyMarginGB = 2

        public var largeDownloadThresholdBytes: Int64
        public var lowBatteryThreshold: Double
        public var unpackedSizeMultiplier: Double
        public var safetyMarginBytes: Int64

        public init(
            largeDownloadThresholdBytes: Int64,
            lowBatteryThreshold: Double,
            unpackedSizeMultiplier: Double,
            safetyMarginBytes: Int64
        ) {
            self.largeDownloadThresholdBytes = max(1, largeDownloadThresholdBytes)
            self.lowBatteryThreshold = min(max(lowBatteryThreshold, 0), 1)
            self.unpackedSizeMultiplier = max(0, unpackedSizeMultiplier)
            self.safetyMarginBytes = max(0, safetyMarginBytes)
        }

        public static func load(from defaults: UserDefaults = .standard) -> Configuration {
            let thresholdMB = integer(
                forKey: largeDownloadThresholdMBKey,
                defaultValue: defaultLargeDownloadThresholdMB,
                defaults: defaults
            )
            let batteryPercent = integer(
                forKey: lowBatteryThresholdPercentKey,
                defaultValue: defaultLowBatteryThresholdPercent,
                defaults: defaults
            )
            let multiplier = defaults.object(forKey: unpackedSizeMultiplierKey) == nil
                ? defaultUnpackedSizeMultiplier
                : defaults.double(forKey: unpackedSizeMultiplierKey)
            let marginGB = integer(
                forKey: safetyMarginGBKey,
                defaultValue: defaultSafetyMarginGB,
                defaults: defaults
            )
            let safeMultiplier = multiplier.isFinite ? min(max(multiplier, 0.5), 100) : defaultUnpackedSizeMultiplier
            return Configuration(
                largeDownloadThresholdBytes: bytes(megabytes: min(max(thresholdMB, 1), 100_000)),
                lowBatteryThreshold: Double(min(max(batteryPercent, 1), 100)) / 100,
                unpackedSizeMultiplier: safeMultiplier,
                safetyMarginBytes: bytes(gigabytes: min(max(marginGB, 0), 1_000))
            )
        }

        private static func integer(forKey key: String, defaultValue: Int, defaults: UserDefaults) -> Int {
            defaults.object(forKey: key) == nil ? defaultValue : defaults.integer(forKey: key)
        }

        private static func bytes(megabytes: Int) -> Int64 {
            Int64(megabytes) * 1_024 * 1_024
        }

        private static func bytes(gigabytes: Int) -> Int64 {
            Int64(gigabytes) * 1_024 * 1_024 * 1_024
        }
    }

    public struct Resources: Equatable, Sendable {
        public var downloadBytes: Int64
        public var snapshotBytes: Int64

        public init(downloadBytes: Int64, snapshotBytes: Int64) {
            self.downloadBytes = max(0, downloadBytes)
            self.snapshotBytes = max(0, snapshotBytes)
        }

        /// Space needed concurrently while Homebrew downloads and expands the artifact,
        /// while Wega retains a rollback snapshot, plus a user-configured safety margin.
        public func requiredDiskBytes(configuration: Configuration) -> Int64 {
            let unpacked = multiplied(downloadBytes, by: configuration.unpackedSizeMultiplier)
            return [downloadBytes, unpacked, snapshotBytes, configuration.safetyMarginBytes]
                .reduce(0, Self.saturatingAdd)
        }

        private func multiplied(_ value: Int64, by multiplier: Double) -> Int64 {
            let result = ceil(Double(value) * multiplier)
            guard result.isFinite, result < Double(Int64.max) else { return Int64.max }
            return Int64(result)
        }

        private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int64.max : sum
        }
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case postpone(reason: String)

        public var isAllowed: Bool { self == .allow }
    }

    public static func decide(
        sizeBytes: Int64,
        largeThresholdBytes: Int64 = 200 * 1024 * 1024,   // 200 MB — small updates never gated
        network: NetworkCondition,
        power: PowerCondition,
        lowBatteryThreshold: Double = 0.20
    ) -> Decision {
        guard sizeBytes >= largeThresholdBytes else { return .allow }
        if network.isExpensive { return .postpone(reason: "połączenie taryfowe (hotspot/komórka)") }
        if network.isConstrained { return .postpone(reason: "tryb oszczędzania danych") }
        if power.thermalSerious { return .postpone(reason: "throttling termiczny") }
        if power.onBattery, let fraction = power.batteryFraction, fraction < lowBatteryThreshold {
            return .postpone(reason: "niski poziom baterii")
        }
        return .allow
    }

    /// Hard resource gate shared by user-present and unattended cask downloads. Unlike
    /// the legacy advisory overload above, no small-download bypass applies: every live
    /// resource veto is authoritative before a snapshot or payload download starts.
    public static func decide(
        resources: Resources,
        availableDiskBytes: Int64?,
        network: NetworkCondition,
        power: PowerCondition,
        configuration: Configuration
    ) -> Decision {
        let required = resources.requiredDiskBytes(configuration: configuration)
        guard let availableDiskBytes else {
            return .postpone(reason: "nie udało się ustalić wolnego miejsca")
        }
        guard availableDiskBytes >= required else {
            return .postpone(
                reason: "niewystarczające miejsce na dysku (wymagane \(required) B, dostępne \(availableDiskBytes) B)"
            )
        }
        if network.isExpensive { return .postpone(reason: "połączenie taryfowe (hotspot/komórka)") }
        if network.isConstrained { return .postpone(reason: "tryb oszczędzania danych") }
        if power.thermalSerious { return .postpone(reason: "throttling termiczny") }
        if power.onBattery,
           let fraction = power.batteryFraction,
           fraction < configuration.lowBatteryThreshold {
            return .postpone(reason: "niski poziom baterii")
        }
        return .allow
    }

    /// Convenience live read of the thermal signal (cheap, public API). Battery and
    /// network must be supplied by the caller (IOPowerSources / NWPathMonitor).
    public static func currentThermalSerious() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }
}
