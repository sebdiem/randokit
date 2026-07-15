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
    public let segmentRanges: [Range<Int>]
    /// Segment indices i whose (i, i+1) pair crosses a GPX segment boundary —
    /// artificial connections that must never receive a projection.
    private let boundaryBreaks: Set<Int>

    public init(trackPoints: [TrackPoint]) {
        self.init(trace: GPXTrace(points: trackPoints))
    }

    public init(trace: GPXTrace) {
        self.init(geometry: TraceGeometry(trace: trace))
    }

    init(geometry: TraceGeometry) {
        trackPoints = geometry.trackPoints
        cumulativeDistances = geometry.cumulativeDistances
        segmentRanges = geometry.segmentRanges
        boundaryBreaks = geometry.boundaryBreaks
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
        let upper = cumulativeDistances.partitionIndex { $0 >= distance }
        guard upper > 0, upper < cumulativeDistances.count
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
        sliceCoordinateSegments(in: range).flatMap { $0 }
    }

    /// Segment-preserving coordinates for a measured route slice. Each inner
    /// array is a real GPX polyline; consumers must render them separately.
    public func sliceCoordinateSegments(
        in requestedRange: ClosedRange<Double>
    ) -> [[(latitude: Double, longitude: Double)]] {
        guard trackPoints.count >= 2, requestedRange.upperBound > requestedRange.lowerBound
        else { return [] }

        var result: [[(latitude: Double, longitude: Double)]] = []
        result.reserveCapacity(segmentRanges.count)
        for segment in segmentRanges where segment.count >= 2 {
            let segmentLower = cumulativeDistances[segment.lowerBound]
            let segmentUpper = cumulativeDistances[segment.upperBound - 1]
            let lower = max(requestedRange.lowerBound, segmentLower)
            let upper = min(requestedRange.upperBound, segmentUpper)
            guard upper > lower,
                let start = coordinate(atDistance: lower, in: segment),
                let end = coordinate(atDistance: upper, in: segment)
            else { continue }

            var coordinates = [start]
            let interiorStart = firstIndex(in: segment) { cumulativeDistances[$0] > lower }
            let interiorEnd = firstIndex(in: segment) { cumulativeDistances[$0] >= upper }
            if interiorStart < interiorEnd {
                coordinates += trackPoints[interiorStart..<interiorEnd]
                    .map { ($0.latitude, $0.longitude) }
            }
            if coordinates.last?.latitude != end.latitude
                || coordinates.last?.longitude != end.longitude
            {
                coordinates.append(end)
            }
            if coordinates.count >= 2 { result.append(coordinates) }
        }
        return result
    }

    private func coordinate(
        atDistance distance: Double, in segment: Range<Int>
    ) -> (latitude: Double, longitude: Double)? {
        guard let firstIndex = segment.first, let lastIndex = segment.last else { return nil }
        let first = trackPoints[firstIndex]
        let last = trackPoints[lastIndex]
        if distance <= cumulativeDistances[firstIndex] { return (first.latitude, first.longitude) }
        if distance >= cumulativeDistances[lastIndex] { return (last.latitude, last.longitude) }

        let upper = self.firstIndex(in: segment) { cumulativeDistances[$0] >= distance }
        guard upper > firstIndex, upper < segment.upperBound else { return nil }
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

    private func firstIndex(
        in range: Range<Int>, where predicate: (Int) -> Bool
    ) -> Int {
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
