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

    public init(trackPoints: [TrackPoint]) {
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
        for index in segments {
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
}
