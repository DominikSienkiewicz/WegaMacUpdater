import Foundation

/// Ordered banners waiting to be read, replacing the single slot that used to hold them.
///
/// A **sticky** banner reports something the user must actually see — today that means a
/// cask whose publisher Team ID changed between versions. It queues and waits its turn.
/// A **transient** banner is the running commentary (scan finished, upgrade summary); only
/// the newest one is worth showing, so a new transient replaces the previous one.
///
/// The failure this fixes: the publisher alert was raised in the middle of an upgrade and
/// the summary banner overwrote it milliseconds later, so the one banner that carries a
/// security signal was the one banner nobody ever saw.
public struct BannerQueue<Banner: Equatable>: Equatable {
    private var sticky: [Banner] = []
    private var transient: Banner?

    public init() {}

    /// The banner to display: sticky ones first, in the order they were raised.
    public var current: Banner? {
        sticky.first ?? transient
    }

    public mutating func enqueue(_ banner: Banner, sticky isSticky: Bool) {
        if isSticky {
            sticky.append(banner)
        } else {
            transient = banner
        }
    }

    /// Dismiss whatever is on screen. Harmless when nothing is.
    public mutating func dismissCurrent() {
        if sticky.isEmpty {
            transient = nil
        } else {
            sticky.removeFirst()
        }
    }

    public mutating func removeAll() {
        sticky.removeAll()
        transient = nil
    }
}
