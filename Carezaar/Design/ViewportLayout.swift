import Foundation

/// Compresses only blank vertical gaps on short screens; text and controls retain their source sizes.
/// Long forms preserve their original scrolling geometry.
enum ViewportLayout {
    static func fitting(_ original: DesignNode, height: Double) -> DesignNode {
        guard original.height <= 1000, height < original.height, height > 0 else { return original }
        let panels = original.children.filter { $0.opacity > 0 && $0.height > 1 && $0.height < original.height * 0.9 }
        let intervals = panels.compactMap { panel -> ClosedRange<Double>? in
            let start = max(0, panel.y), end = min(original.height, panel.y + panel.height)
            return start <= end ? start...end : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for interval in intervals {
            if let last = merged.last, interval.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            } else { merged.append(interval) }
        }
        let occupied = merged.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let blanks = original.height - occupied
        let reduction = original.height - height
        guard blanks > reduction + 16 else { return original }
        let fraction = reduction / blanks
        func shift(before position: Double) -> Double {
            var end = 0.0, blank = 0.0
            for interval in merged {
                blank += max(0, min(position, interval.lowerBound) - end)
                if position <= interval.upperBound { return blank * fraction }
                end = interval.upperBound
            }
            return (blank + max(0, position - end)) * fraction
        }
        var result = original
        result.height = height
        result.children = original.children.map { child in
            var fitted = child
            if child.height >= original.height * 0.9 && child.y <= 0 { fitted.height = height }
            else { fitted.y -= shift(before: child.y) }
            return fitted
        }
        return result
    }
}
