import Foundation

public enum Geo {
    public static let earthRadiusMeters = 6_371_000.0

    /// Great-circle distance in meters (haversine — ample accuracy at hiking scale).
    public static func distanceMeters(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double
    ) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    public static func distanceMeters(from a: TrackPoint, to b: TrackPoint) -> Double {
        distanceMeters(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
    }
}

public struct ProfilePoint: Equatable, Sendable {
    /// Meters from the start of the trace.
    public var distance: Double
    /// Meters above sea level.
    public var elevation: Double

    public init(distance: Double, elevation: Double) {
        self.distance = distance
        self.elevation = elevation
    }
}

/// A trace flattened to (distance-from-start, elevation) — the single structure
/// behind the elevation profile, position-along-trace projection, and segment stats.
public struct LinearizedTrace: Equatable, Sendable {
    public var points: [ProfilePoint]

    /// Peak-preserving reduction for display: buckets of equal point count,
    /// keeping each bucket's min and max elevation. Charts stay visually
    /// identical while mark count drops orders of magnitude. Never use the
    /// result for measurements — keep the full-resolution trace for math.
    public func downsampled(maxBuckets: Int = 500) -> [ProfilePoint] {
        guard points.count > maxBuckets * 2, let last = points.last else { return points }
        var result: [ProfilePoint] = [points[0]]
        let bucketSize = Double(points.count - 2) / Double(maxBuckets)
        for bucket in 0..<maxBuckets {
            let start = 1 + Int(Double(bucket) * bucketSize)
            let end = min(1 + Int(Double(bucket + 1) * bucketSize), points.count - 1)
            guard start < end else { continue }
            let slice = points[start..<end]
            guard let lowest = slice.min(by: { $0.elevation < $1.elevation }),
                let highest = slice.max(by: { $0.elevation < $1.elevation })
            else { continue }
            if lowest == highest {
                result.append(lowest)
            } else if lowest.distance < highest.distance {
                result.append(lowest)
                result.append(highest)
            } else {
                result.append(highest)
                result.append(lowest)
            }
        }
        result.append(last)
        return result
    }

    public var totalDistance: Double { points.last?.distance ?? 0 }

    /// Points missing elevation take the nearest earlier known value (or the first
    /// known value overall), so a profile survives partially-tagged GPX files.
    public init(trackPoints: [TrackPoint]) {
        var result: [ProfilePoint] = []
        result.reserveCapacity(trackPoints.count)
        var cumulative = 0.0
        var lastKnownElevation = trackPoints.first(where: { $0.elevation != nil })?.elevation ?? 0
        for (index, point) in trackPoints.enumerated() {
            if index > 0 {
                cumulative += Geo.distanceMeters(from: trackPoints[index - 1], to: point)
            }
            if let elevation = point.elevation {
                lastKnownElevation = elevation
            }
            result.append(ProfilePoint(distance: cumulative, elevation: lastKnownElevation))
        }
        self.points = result
    }
}
