import Foundation
import Network
#if canImport(IOKit)
import IOKit.ps
#endif

/// Live system-condition probes feeding `DownloadGate` (**FEAT-07 / I-4**).
///
/// Scope: thermal state (`ProcessInfo`, cheap+public) and network cost
/// (`NWPathMonitor.isExpensive`/`isConstrained`). Battery-level probing
/// (IOKit `IOPowerSources`) is a deliberate follow-up — `DownloadGate` already
/// supports it (pure + tested); here we report thermal+network only, which are
/// the primary FinOps signals (metered link, thermal throttle).
public enum LiveConditions {

    /// One-shot read of the current network path (expensive/constrained). Falls
    /// back to `.unrestricted` after `timeout` if no path update arrives.
    public static func network(timeout: TimeInterval = 1.5) async -> NetworkCondition {
        final class Box: @unchecked Sendable {
            let monitor = NWPathMonitor()
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        let box = Box()
        return await withCheckedContinuation { (continuation: CheckedContinuation<NetworkCondition, Never>) in
            box.monitor.pathUpdateHandler = { path in
                guard box.claim() else { return }
                continuation.resume(returning: NetworkCondition(
                    isExpensive: path.isExpensive, isConstrained: path.isConstrained))
                box.monitor.cancel()
            }
            box.monitor.start(queue: DispatchQueue(label: "com.wega.netcheck"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard box.claim() else { return }
                continuation.resume(returning: .unrestricted)
                box.monitor.cancel()
            }
        }
    }

    /// Power read: thermal (ProcessInfo) + battery state via IOKit `IOPowerSources`
    /// (FEAT-07). Memory rules: `Copy*` → takeRetained, `Get*` → takeUnretained.
    /// Any probe failure degrades gracefully (onBattery=false / fraction=nil).
    public static func power() -> PowerCondition {
        let thermal = DownloadGate.currentThermalSerious()
        #if canImport(IOKit)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerCondition(onBattery: false, batteryFraction: nil, thermalSerious: thermal)
        }
        // Currently-providing source: "Battery Power" when running off the battery.
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onBattery = (providing == kIOPSBatteryPowerValue)

        var fraction: Double?
        if let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
                else { continue }
                if let current = desc[kIOPSCurrentCapacityKey] as? Int,
                   let maximum = desc[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    fraction = Double(current) / Double(maximum)
                    break
                }
            }
        }
        return PowerCondition(onBattery: onBattery, batteryFraction: fraction, thermalSerious: thermal)
        #else
        return PowerCondition(onBattery: false, batteryFraction: nil, thermalSerious: thermal)
        #endif
    }

    /// Convenience: both conditions for a `DownloadGate.decide(...)` call.
    public static func snapshot() async -> (network: NetworkCondition, power: PowerCondition) {
        async let net = network()
        let pow = power()
        return (await net, pow)
    }
}
