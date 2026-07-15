import CoreLocation
import RandoKit
import XCTest

@testable import Rando

@MainActor
final class NavigationSessionTests: XCTestCase {
    func testSelectionAcrossDisconnectedTraceProducesSeparateOverlays() {
        let trace = GPXTrace(
            points: [
                TrackPoint(latitude: 45.000, longitude: 6.00, elevation: 100),
                TrackPoint(latitude: 45.002, longitude: 6.00, elevation: 110),
                TrackPoint(latitude: 45.002, longitude: 6.02, elevation: 900),
                TrackPoint(latitude: 45.000, longitude: 6.02, elevation: 910),
            ],
            segmentRanges: [0..<2, 2..<4])
        let prepared = PreparedTrace(trace: trace)
        let active = TraceLibrary.Active(
            entryID: "test", prepared: prepared,
            displayProfile: prepared.linearized.downsampled(), waypointMarks: [])
        let session = NavigationSession()
        session.activate(active, lastFix: nil)

        session.selectedKmRange = 0.05...(prepared.geometry.totalDistance / 1_000 - 0.05)

        XCTAssertEqual(session.selectionCoordinateSegments.count, 2)
        XCTAssertTrue(
            session.selectionCoordinateSegments[0].allSatisfy { abs($0.longitude - 6.00) < 0.000_001 })
        XCTAssertTrue(
            session.selectionCoordinateSegments[1].allSatisfy { abs($0.longitude - 6.02) < 0.000_001 })
    }
}
