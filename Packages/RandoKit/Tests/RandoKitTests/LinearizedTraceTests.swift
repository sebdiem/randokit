import Foundation
import Testing

@testable import RandoKit

struct LinearizedTraceTests {
    @Test func distanceAccumulatesAlongLatitude() {
        // 0.01° of latitude ≈ 1111.95 m regardless of longitude.
        let points = [
            TrackPoint(latitude: 45.00, longitude: 6.0, elevation: 1000),
            TrackPoint(latitude: 45.01, longitude: 6.0, elevation: 1100),
            TrackPoint(latitude: 45.02, longitude: 6.0, elevation: 1050),
        ]
        let trace = LinearizedTrace(trackPoints: points)
        #expect(trace.points.count == 3)
        #expect(trace.points[0].distance == 0)
        #expect(abs(trace.points[1].distance - 1111.95) < 1.0)
        #expect(abs(trace.totalDistance - 2223.9) < 2.0)
    }

    @Test func missingElevationCarriesLastKnownValue() {
        let points = [
            TrackPoint(latitude: 45.00, longitude: 6.0, elevation: nil),
            TrackPoint(latitude: 45.01, longitude: 6.0, elevation: 1200),
            TrackPoint(latitude: 45.02, longitude: 6.0, elevation: nil),
        ]
        let trace = LinearizedTrace(trackPoints: points)
        #expect(trace.points[0].elevation == 1200)  // first known value backfills the start
        #expect(trace.points[2].elevation == 1200)
    }

    @Test func emptyTraceIsEmpty() {
        let trace = LinearizedTrace(trackPoints: [])
        #expect(trace.points.isEmpty)
        #expect(trace.totalDistance == 0)
    }

    @Test func downsamplingPreservesExtremesAndEndpoints() {
        // 8000 points with a single sharp spike and dip hidden in the noise.
        var points: [TrackPoint] = []
        for i in 0..<8000 {
            var elevation = 1000.0 + Double(i % 7)
            if i == 3210 { elevation = 2500 }
            if i == 6100 { elevation = 400 }
            points.append(
                TrackPoint(latitude: 45 + Double(i) * 0.0001, longitude: 6, elevation: elevation))
        }
        let full = LinearizedTrace(trackPoints: points)
        let reduced = full.downsampled(maxBuckets: 500)

        #expect(reduced.count <= 1002)
        #expect(reduced.count > 400)
        #expect(reduced.map(\.elevation).max() == 2500)
        #expect(reduced.map(\.elevation).min() == 400)
        #expect(reduced.first == full.points.first)
        #expect(reduced.last == full.points.last)
        // Still sorted by distance so the chart renders a valid path.
        #expect(zip(reduced, reduced.dropFirst()).allSatisfy { $0.distance <= $1.distance })
    }

    @Test func downsamplingLeavesSmallTracesUntouched() {
        let trace = LinearizedTrace(trackPoints: (0..<100).map {
            TrackPoint(latitude: 45 + Double($0) * 0.001, longitude: 6, elevation: 1000)
        })
        #expect(trace.downsampled(maxBuckets: 500) == trace.points)
    }
}
