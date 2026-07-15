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
            slice = points.filter { range.contains($0.distance) }
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
}
