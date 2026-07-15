import Foundation

public struct ElevationStats: Equatable, Sendable {
    public var gain: Double
    public var loss: Double

    public init(gain: Double = 0, loss: Double = 0) {
        self.gain = gain
        self.loss = loss
    }
}

extension LinearizedTrace {
    /// Cumulative climb (D+) and descent (D−) over a slice of the profile,
    /// deadband-filtered: elevation only counts once it moves more than
    /// `threshold` meters away from the last committed level, so small
    /// oscillations (sensor or DEM noise) don't inflate the totals.
    public func elevationStats(
        in range: ClosedRange<Double>? = nil, threshold: Double = 3
    ) -> ElevationStats {
        let slice: [ProfilePoint]
        if let range {
            // Interpolated boundary points so that a range falling between
            // two samples still measures the elevation change across it.
            var built: [ProfilePoint] = []
            if let start = elevation(atDistance: range.lowerBound) {
                built.append(ProfilePoint(distance: range.lowerBound, elevation: start))
            }
            let lower = points.partitionIndex { $0.distance > range.lowerBound }
            let upper = points.partitionIndex { $0.distance >= range.upperBound }
            if lower < upper {
                built += points[lower..<upper]
            }
            if let end = elevation(atDistance: range.upperBound) {
                built.append(ProfilePoint(distance: range.upperBound, elevation: end))
            }
            slice = built
        } else {
            slice = points
        }
        guard var anchor = slice.first?.elevation else { return ElevationStats() }

        var stats = ElevationStats()
        for point in slice.dropFirst() {
            let delta = point.elevation - anchor
            if delta >= threshold {
                stats.gain += delta
                anchor = point.elevation
            } else if delta <= -threshold {
                stats.loss += -delta
                anchor = point.elevation
            }
        }
        return stats
    }

    /// Linearly interpolated elevation at a distance-along value (clamped).
    public func elevation(atDistance distance: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if distance <= first.distance { return first.elevation }
        if distance >= last.distance { return last.elevation }
        let upper = points.partitionIndex { $0.distance >= distance }
        guard upper > 0, upper < points.count else { return first.elevation }
        let a = points[upper - 1]
        let b = points[upper]
        let span = b.distance - a.distance
        let t = span > 0 ? (distance - a.distance) / span : 0
        return a.elevation + t * (b.elevation - a.elevation)
    }
}

extension Array {
    /// First index whose element satisfies `belongsInSecondPartition`, assuming
    /// the array is partitioned on that predicate (binary search, O(log n)).
    func partitionIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let mid = index(low, offsetBy: distance(from: low, to: high) / 2)
            if belongsInSecondPartition(self[mid]) {
                high = mid
            } else {
                low = index(after: mid)
            }
        }
        return low
    }
}
