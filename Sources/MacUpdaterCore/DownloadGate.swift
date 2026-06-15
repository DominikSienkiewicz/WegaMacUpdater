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

    /// Convenience live read of the thermal signal (cheap, public API). Battery and
    /// network must be supplied by the caller (IOPowerSources / NWPathMonitor).
    public static func currentThermalSerious() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }
}
