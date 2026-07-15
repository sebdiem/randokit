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
}
