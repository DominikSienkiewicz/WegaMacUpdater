import Foundation
import Network

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

    /// Thermal-only power read (battery level is a documented TODO).
    public static func power() -> PowerCondition {
        PowerCondition(onBattery: false, batteryFraction: nil, thermalSerious: DownloadGate.currentThermalSerious())
    }

    /// Convenience: both conditions for a `DownloadGate.decide(...)` call.
    public static func snapshot() async -> (network: NetworkCondition, power: PowerCondition) {
        async let net = network()
        let pow = power()
        return (await net, pow)
    }
}
