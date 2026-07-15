import Foundation

/// Canonical, segment-aware geometry shared by every distance-based trace feature.
///
/// `GPXTrace` stores points flattened for efficient iteration. This type restores
/// the segment invariant once, computes cumulative walking distance once, and is
/// then reused by projection and profile preparation. Crossing a GPX segment
/// boundary contributes zero distance.
public struct TraceGeometry: Sendable {
    public let trackPoints: [TrackPoint]
    public let segmentRanges: [Range<Int>]
    public let cumulativeDistances: [Double]

    /// Segment indices `i` whose `(i, i + 1)` pair is a disconnected boundary.
    let boundaryBreaks: Set<Int>

    public init(trace: GPXTrace) {
        trackPoints = trace.points
        segmentRanges = Self.normalizedRanges(trace.segmentRanges, pointCount: trace.points.count)

        var cumulative = Array(repeating: 0.0, count: trace.points.count)
        var breaks = Set<Int>()
        var total = 0.0

        for (segmentIndex, range) in segmentRanges.enumerated() {
            guard let first = range.first else { continue }
            cumulative[first] = total
            if range.count >= 2 {
                for index in (first + 1)..<range.upperBound {
                    total += Geo.distanceMeters(from: trace.points[index - 1], to: trace.points[index])
                    cumulative[index] = total
                }
            }
            if segmentIndex < segmentRanges.count - 1 {
                breaks.insert(range.upperBound - 1)
            }
        }

        cumulativeDistances = cumulative
        boundaryBreaks = breaks
    }

    public var totalDistance: Double { cumulativeDistances.last ?? 0 }

    /// The public model is mutable, so defend all geometry consumers against a
    /// stale or malformed range list. Valid GPX ranges cover the flattened point
    /// array exactly once, in order; otherwise treating it as one segment is the
    /// safest non-crashing fallback.
    private static func normalizedRanges(
        _ ranges: [Range<Int>], pointCount: Int
    ) -> [Range<Int>] {
        guard pointCount > 0 else { return [] }
        var expectedLowerBound = 0
        for range in ranges {
            guard
                !range.isEmpty,
                range.lowerBound == expectedLowerBound,
                range.upperBound <= pointCount
            else { return [0..<pointCount] }
            expectedLowerBound = range.upperBound
        }
        return !ranges.isEmpty && expectedLowerBound == pointCount ? ranges : [0..<pointCount]
    }
}

/// Immutable, fully prepared trace snapshot. Building it is O(n); all live GPS
/// projection and UI reads use its precomputed arrays.
public struct PreparedTrace: Sendable {
    public let trace: GPXTrace
    public let geometry: TraceGeometry
    public let linearized: LinearizedTrace
    public let projector: TraceProjector

    public init(trace: GPXTrace) {
        let geometry = TraceGeometry(trace: trace)
        self.trace = trace
        self.geometry = geometry
        linearized = LinearizedTrace(trace: trace, geometry: geometry)
        projector = TraceProjector(geometry: geometry)
    }
}
