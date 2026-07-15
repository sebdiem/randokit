import Foundation
import Testing

@testable import RandoKit

struct GPXWriterTests {
    @Test func roundTripPreservesEverything() throws {
        let original = GPXTrace(
            name: "Aiguille & <Lac>",
            points: [
                TrackPoint(
                    latitude: 45.9614, longitude: 6.8871, elevation: 1872.78,
                    time: Date(timeIntervalSince1970: 1_780_000_000.25)),
                TrackPoint(latitude: 45.9718, longitude: 6.8885, elevation: 2120.18),
                TrackPoint(latitude: 45.9801, longitude: 6.8859),
            ],
            waypoints: [
                Waypoint(
                    latitude: 45.9801, longitude: 6.8859, name: "Refuge", elevation: 2352,
                    symbol: "Campground", type: "nuit")
            ])

        let reparsed = try GPXParser().parse(GPXWriter().write(original))

        #expect(reparsed.name == original.name)
        #expect(reparsed.waypoints == original.waypoints)
        #expect(reparsed.points.count == original.points.count)
        for (a, b) in zip(reparsed.points, original.points) {
            #expect(abs(a.latitude - b.latitude) < 1e-6)
            #expect(abs(a.longitude - b.longitude) < 1e-6)
            #expect(a.elevation == b.elevation)
            #expect(a.time == b.time)
        }
    }

    @Test func writesNoElevationTagWhenAbsent() {
        let trace = GPXTrace(points: [TrackPoint(latitude: 45, longitude: 6)])
        let xml = GPXWriter().write(trace)
        #expect(!xml.contains("<ele>"))
        #expect(xml.contains("lat=\"45\""))
    }

    @Test func roundTripPreservesSegmentBoundaries() throws {
        let original = GPXTrace(
            name: "Deux tronçons",
            points: [
                TrackPoint(latitude: 45.00, longitude: 6.0),
                TrackPoint(latitude: 45.01, longitude: 6.0),
                TrackPoint(latitude: 45.05, longitude: 6.1),
                TrackPoint(latitude: 45.06, longitude: 6.1),
            ],
            segmentRanges: [0..<2, 2..<4])
        let reparsed = try GPXParser().parse(GPXWriter().write(original))
        #expect(reparsed.segmentRanges == original.segmentRanges)
    }
}
