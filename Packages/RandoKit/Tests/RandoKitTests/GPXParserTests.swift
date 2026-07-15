import Foundation
import Testing

@testable import RandoKit

private let sampleGPX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test">
      <metadata><name>Tour du Lac</name></metadata>
      <wpt lat="45.1000" lon="6.2000">
        <ele>1650.0</ele>
        <name>Refuge</name>
      </wpt>
      <trk>
        <name>Tour du Lac — trace</name>
        <trkseg>
          <trkpt lat="45.1000" lon="6.2000"><ele>1600.0</ele><time>2026-07-01T08:00:00Z</time></trkpt>
          <trkpt lat="45.1010" lon="6.2000"><ele>1612.5</ele><time>2026-07-01T08:02:30.500Z</time></trkpt>
        </trkseg>
        <trkseg>
          <trkpt lat="45.1020" lon="6.2010"></trkpt>
        </trkseg>
      </trk>
    </gpx>
    """

struct GPXParserTests {
    @Test func parsesTrackPointsAcrossSegments() throws {
        let trace = try GPXParser().parse(sampleGPX)
        #expect(trace.points.count == 3)
        #expect(trace.points[0].latitude == 45.1)
        #expect(trace.points[0].elevation == 1600.0)
        #expect(trace.points[2].elevation == nil)
    }

    @Test func preservesSegmentBoundaries() throws {
        let trace = try GPXParser().parse(sampleGPX)
        #expect(trace.segmentRanges == [0..<2, 2..<3])
    }

    @Test func rejectsSinglePointTrace() {
        #expect(throws: GPXError.noTrack) {
            try GPXParser().parse(
                "<gpx version=\"1.1\"><trk><trkseg><trkpt lat=\"45\" lon=\"6\"></trkpt></trkseg></trk></gpx>"
            )
        }
    }

    @Test func parsesMetadataNameFirst() throws {
        let trace = try GPXParser().parse(sampleGPX)
        #expect(trace.name == "Tour du Lac")
    }

    @Test func parsesTimesIncludingFractionalSeconds() throws {
        let trace = try GPXParser().parse(sampleGPX)
        let t0 = try #require(trace.points[0].time)
        let t1 = try #require(trace.points[1].time)
        #expect(abs(t1.timeIntervalSince(t0) - 150.5) < 0.001)
    }

    @Test func parsesWaypointsWithNames() throws {
        let trace = try GPXParser().parse(sampleGPX)
        #expect(trace.waypoints.count == 1)
        #expect(trace.waypoints[0].name == "Refuge")
        #expect(trace.waypoints[0].elevation == 1650.0)
    }

    @Test func parsesRoutesLikeTracks() throws {
        let gpx = """
            <gpx version="1.1"><rte><name>Route</name>
            <rtept lat="45.0" lon="6.0"><ele>1000</ele></rtept>
            <rtept lat="45.001" lon="6.0"><ele>1010</ele></rtept>
            </rte></gpx>
            """
        let trace = try GPXParser().parse(gpx)
        #expect(trace.points.count == 2)
        #expect(trace.name == "Route")
    }

    @Test func throwsOnMalformedXML() {
        #expect(throws: GPXError.self) {
            try GPXParser().parse("<gpx><trk><trkseg><trkpt lat=\"45")
        }
    }

    @Test func throwsWhenNoPoints() {
        #expect(throws: GPXError.noTrack) {
            try GPXParser().parse("<gpx version=\"1.1\"><metadata><name>Empty</name></metadata></gpx>")
        }
    }
}
