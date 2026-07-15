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

    /// Original GPX segment. Charts and statistics use this to avoid drawing or
    /// measuring an artificial connection between disconnected segments.
    public var segmentIndex: Int

    public init(distance: Double, elevation: Double, segmentIndex: Int = 0) {
        self.distance = distance
        self.elevation = elevation
        self.segmentIndex = segmentIndex
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
    ///
    /// With `range` (meters along the trace), only that slice is reduced,
    /// with interpolated boundary points so the curve reaches the plot edges.
    /// A slice already small enough is returned at full resolution — this is
    /// what makes zooming reveal real detail.
    public func downsampled(
        in range: ClosedRange<Double>? = nil, maxBuckets: Int = 500
    ) -> [ProfilePoint] {
        guard let range else {
            return Self.bucketReduce(points, maxBuckets: maxBuckets)
        }
        return Self.bucketReduce(profileSlice(in: range), maxBuckets: maxBuckets)
    }

    private static func bucketReduce(_ points: [ProfilePoint], maxBuckets: Int) -> [ProfilePoint] {
        guard points.count > maxBuckets * 2, let last = points.last else { return points }
        var segmentSlices: [ArraySlice<ProfilePoint>] = []
        var start = points.startIndex
        for index in points.indices.dropFirst()
            where points[index].segmentIndex != points[index - 1].segmentIndex
        {
            segmentSlices.append(points[start..<index])
            start = index
        }
        segmentSlices.append(points[start..<points.endIndex])

        var result: [ProfilePoint] = []
        result.reserveCapacity(min(points.count, maxBuckets * 2 + segmentSlices.count * 2))
        for slice in segmentSlices {
            let proportionalBuckets = max(
                1, Int((Double(slice.count) / Double(points.count) * Double(maxBuckets)).rounded()))
            result += bucketReduceSingleSegment(slice, maxBuckets: proportionalBuckets)
        }
        // Preserve the exact final endpoint even if proportional rounding gave
        // the last segment a tiny budget.
        if result.last != last { result.append(last) }
        return result
    }

    private static func bucketReduceSingleSegment(
        _ points: ArraySlice<ProfilePoint>, maxBuckets: Int
    ) -> [ProfilePoint] {
        guard points.count > maxBuckets * 2, let first = points.first, let last = points.last
        else { return Array(points) }
        var result = [first]
        let interiorCount = points.count - 2
        let bucketSize = Double(interiorCount) / Double(maxBuckets)
        for bucket in 0..<maxBuckets {
            let startOffset = 1 + Int(Double(bucket) * bucketSize)
            let endOffset = min(1 + Int(Double(bucket + 1) * bucketSize), points.count - 1)
            guard startOffset < endOffset else { continue }
            let start = points.index(points.startIndex, offsetBy: startOffset)
            let end = points.index(points.startIndex, offsetBy: endOffset)
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

    /// Points missing elevation take the nearest earlier known value within their
    /// segment (or that segment's first known value), so a profile survives
    /// partially-tagged GPX files without leaking values across a discontinuity.
    public init(trackPoints: [TrackPoint]) {
        self.init(trace: GPXTrace(points: trackPoints))
    }

    public init(trace: GPXTrace) {
        self.init(trace: trace, geometry: TraceGeometry(trace: trace))
    }

    init(trace: GPXTrace, geometry: TraceGeometry) {
        var result: [ProfilePoint] = []
        result.reserveCapacity(trace.points.count)
        for (segmentIndex, range) in geometry.segmentRanges.enumerated() {
            var lastKnownElevation = trace.points[range]
                .first(where: { $0.elevation != nil })?.elevation ?? 0
            for pointIndex in range {
                let point = trace.points[pointIndex]
                if let elevation = point.elevation {
                    lastKnownElevation = elevation
                }
                result.append(
                    ProfilePoint(
                        distance: geometry.cumulativeDistances[pointIndex],
                        elevation: lastKnownElevation,
                        segmentIndex: segmentIndex))
            }
        }
        self.points = result
    }

    /// Segment-aware profile slice with interpolated boundaries. Returned
    /// segment groups remain contiguous and never interpolate across a GPX gap.
    func profileSlice(in range: ClosedRange<Double>) -> [ProfilePoint] {
        guard range.upperBound >= range.lowerBound, !points.isEmpty else { return [] }
        var result: [ProfilePoint] = []
        var segmentStart = points.startIndex

        func appendSegment(_ segment: ArraySlice<ProfilePoint>) {
            guard let first = segment.first, let last = segment.last else { return }
            let lower = max(range.lowerBound, first.distance)
            let upper = min(range.upperBound, last.distance)
            // A zero-length overlap at a shared boundary belongs to the segment
            // on the side with actual range, not both disconnected segments.
            guard upper > lower || (first.distance == last.distance && range.contains(first.distance))
            else { return }

            if let start = Self.interpolatedPoint(at: lower, in: segment) {
                result.append(start)
            }
            result += segment.filter { $0.distance > lower && $0.distance < upper }
            if upper > lower, let end = Self.interpolatedPoint(at: upper, in: segment),
                result.last != end
            {
                result.append(end)
            }
        }

        for index in points.indices.dropFirst()
            where points[index].segmentIndex != points[index - 1].segmentIndex
        {
            appendSegment(points[segmentStart..<index])
            segmentStart = index
        }
        appendSegment(points[segmentStart..<points.endIndex])
        return result
    }

    private static func interpolatedPoint(
        at distance: Double, in segment: ArraySlice<ProfilePoint>
    ) -> ProfilePoint? {
        guard let first = segment.first, let last = segment.last else { return nil }
        if distance <= first.distance { return first }
        if distance >= last.distance { return last }

        var low = segment.startIndex
        var high = segment.endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if segment[mid].distance >= distance { high = mid } else { low = mid + 1 }
        }
        guard low > segment.startIndex, low < segment.endIndex else { return first }
        let a = segment[low - 1]
        let b = segment[low]
        let span = b.distance - a.distance
        let t = span > 0 ? (distance - a.distance) / span : 0
        return ProfilePoint(
            distance: distance,
            elevation: a.elevation + t * (b.elevation - a.elevation),
            segmentIndex: first.segmentIndex)
    }
}
