import Foundation

public struct TraceProjection: Equatable, Sendable {
    /// Meters from the trace start (profile abscissa).
    public var distanceAlong: Double
    /// Meters between the position and the nearest point of the trace.
    public var crossTrackDistance: Double
    /// Index of the nearest segment (into the track points array).
    public var segmentIndex: Int

    public init(distanceAlong: Double, crossTrackDistance: Double, segmentIndex: Int) {
        self.distanceAlong = distanceAlong
        self.crossTrackDistance = crossTrackDistance
        self.segmentIndex = segmentIndex
    }
}

/// Projects GPS positions onto a trace. Distances between consecutive points
/// are small at hiking scale, so each segment is treated as a straight line in
/// a local equirectangular plane centered on the query point.
public struct TraceProjector: Sendable {
    public let trackPoints: [TrackPoint]
    public let cumulativeDistances: [Double]
    /// Segment indices i whose (i, i+1) pair crosses a GPX segment boundary —
    /// artificial connections that must never receive a projection.
    private let boundaryBreaks: Set<Int>

    public init(trackPoints: [TrackPoint]) {
        self.init(trace: GPXTrace(points: trackPoints))
    }

    public init(trace: GPXTrace) {
        let trackPoints = trace.points
        self.trackPoints = trackPoints
        var cumulative: [Double] = []
        cumulative.reserveCapacity(trackPoints.count)
        var total = 0.0
        for (index, point) in trackPoints.enumerated() {
            if index > 0 {
                total += Geo.distanceMeters(from: trackPoints[index - 1], to: point)
            }
            cumulative.append(total)
        }
        self.cumulativeDistances = cumulative
        var breaks = Set<Int>()
        for range in trace.segmentRanges where range.upperBound < trackPoints.count {
            breaks.insert(range.upperBound - 1)
        }
        self.boundaryBreaks = breaks
    }

    public var totalDistance: Double { cumulativeDistances.last ?? 0 }

    /// Nearest point of the trace. Pass the previous result's `segmentIndex`
    /// as `nearSegment` to keep the search local (stable and O(1) per fix);
    /// if the local window's best is implausibly far, the search widens to
    /// the whole trace so rejoining after a detour still works.
    public func project(
        latitude: Double, longitude: Double, nearSegment hint: Int? = nil, window: Int = 30
    ) -> TraceProjection? {
        guard trackPoints.count >= 2 else { return nil }

        let segments: Range<Int>
        if let hint {
            let lower = max(0, hint - window)
            let upper = min(trackPoints.count - 1, hint + window + 1)
            segments = lower..<upper
        } else {
            segments = 0..<(trackPoints.count - 1)
        }

        let metersPerDegree = 111_320.0
        let cosLat = cos(latitude * .pi / 180)
        func planeXY(_ point: TrackPoint) -> (x: Double, y: Double) {
            (
                (point.longitude - longitude) * cosLat * metersPerDegree,
                (point.latitude - latitude) * metersPerDegree
            )
        }

        var best: TraceProjection?
        for index in segments where !boundaryBreaks.contains(index) {
            let a = planeXY(trackPoints[index])
            let b = planeXY(trackPoints[index + 1])
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0
                ? 0 : min(1, max(0, -(a.x * dx + a.y * dy) / lengthSquared))
            let px = a.x + t * dx
            let py = a.y + t * dy
            let distance = (px * px + py * py).squareRoot()
            if best == nil || distance < best!.crossTrackDistance {
                let segmentLength = cumulativeDistances[index + 1] - cumulativeDistances[index]
                best = TraceProjection(
                    distanceAlong: cumulativeDistances[index] + t * segmentLength,
                    crossTrackDistance: distance,
                    segmentIndex: index)
            }
        }

        if hint != nil, let localBest = best, localBest.crossTrackDistance > 200 {
            return project(latitude: latitude, longitude: longitude, nearSegment: nil)
        }
        return best
    }

    /// Interpolated position at a distance-along value (clamped to the trace).
    public func coordinate(atDistance distance: Double) -> (latitude: Double, longitude: Double)? {
        guard let first = trackPoints.first, let last = trackPoints.last else { return nil }
        if distance <= 0 { return (first.latitude, first.longitude) }
        if distance >= totalDistance { return (last.latitude, last.longitude) }
        guard let upper = cumulativeDistances.firstIndex(where: { $0 >= distance }), upper > 0
        else { return (first.latitude, first.longitude) }
        let lower = upper - 1
        let span = cumulativeDistances[upper] - cumulativeDistances[lower]
        let t = span > 0 ? (distance - cumulativeDistances[lower]) / span : 0
        let a = trackPoints[lower]
        let b = trackPoints[upper]
        return (
            a.latitude + t * (b.latitude - a.latitude),
            a.longitude + t * (b.longitude - a.longitude)
        )
    }

    /// Coordinates of the trace slice between two distance-along values, with
    /// interpolated endpoints — always at least two coordinates for a
    /// non-empty range, even between two samples.
    public func sliceCoordinates(
        in range: ClosedRange<Double>
    ) -> [(latitude: Double, longitude: Double)] {
        guard trackPoints.count >= 2, range.upperBound > range.lowerBound else { return [] }
        var result: [(latitude: Double, longitude: Double)] = []
        if let start = coordinate(atDistance: range.lowerBound) {
            result.append(start)
        }
        for (index, point) in trackPoints.enumerated()
        where cumulativeDistances[index] > range.lowerBound
            && cumulativeDistances[index] < range.upperBound
        {
            result.append((point.latitude, point.longitude))
        }
        if let end = coordinate(atDistance: range.upperBound) {
            result.append(end)
        }
        return result
    }
}
