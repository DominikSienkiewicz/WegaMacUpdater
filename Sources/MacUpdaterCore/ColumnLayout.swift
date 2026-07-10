import Foundation
import CoreGraphics

/// Column arithmetic for weighted tables.
///
/// Written out because the obvious spelling in SwiftUI — `.frame(maxWidth: .infinity * weight)`
/// — silently does nothing: `infinity * 1.6 == infinity == infinity * 0.6`. Every column
/// claims an unbounded width, the stack splits the space evenly, and the weights are decoration.
public enum ColumnLayout {
    /// Distributes `total` (minus the inter-column spacing) across the columns in proportion
    /// to their weights. Returns one width per weight, summing to the distributable width.
    public static func proportionalWidths(total: CGFloat, weights: [CGFloat], spacing: CGFloat = 0) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return weights.map { _ in 0 } }

        let gaps = spacing * CGFloat(weights.count - 1)
        let distributable = max(0, total - gaps)
        return weights.map { distributable * ($0 / totalWeight) }
    }
}
