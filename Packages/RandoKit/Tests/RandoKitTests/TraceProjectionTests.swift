import Foundation
import Testing

@testable import RandoKit

/// Straight north-south trace: 1 km along a meridian, points every ~111 m.
private let straightTrace = (0...10).map {
    TrackPoint(latitude: 45.0 + Double($0) * 0.001, longitude: 6.0)
}

struct TraceProjectionTests {
    @Test func pointBesideMiddleProjectsToMiddle() throws {
        let projector = TraceProjector(trackPoints: straightTrace)
        // Halfway up, ~78 m east of the line (0.001° lon at 45° ≈ 78.6 m).
        let projection = try #require(projector.project(latitude: 45.005, longitude: 6.001))
        #expect(abs(projection.distanceAlong - projector.totalDistance / 2) < 1)
        #expect(abs(projection.crossTrackDistance - 78.6) < 2)
    }

    @Test func pointBeyondEndClampsToEnd() throws {
        let projector = TraceProjector(trackPoints: straightTrace)
        let projection = try #require(projector.project(latitude: 45.02, longitude: 6.0))
        #expect(projection.distanceAlong == projector.totalDistance)
        #expect(projection.segmentIndex == straightTrace.count - 2)
    }

    @Test func hintedSearchMatchesGlobalSearch() throws {
        let projector = TraceProjector(trackPoints: straightTrace)
        let global = try #require(projector.project(latitude: 45.0042, longitude: 6.0003))
        let hinted = try #require(
            projector.project(latitude: 45.0042, longitude: 6.0003, nearSegment: global.segmentIndex))
        #expect(hinted == global)
    }

    @Test func farFromLocalWindowFallsBackToGlobalSearch() throws {
        let projector = TraceProjector(trackPoints: straightTrace)
        // Hint at the start, but the position is near the end (>200 m from
        // the hinted window with a tiny window size).
        let projection = try #require(
            projector.project(latitude: 45.0098, longitude: 6.0, nearSegment: 0, window: 1))
        #expect(abs(projection.distanceAlong - projector.totalDistance * 0.98) < 5)
    }

    @Test func onTraceCrossDistanceIsZero() throws {
        let projector = TraceProjector(trackPoints: straightTrace)
        let projection = try #require(projector.project(latitude: 45.0035, longitude: 6.0))
        #expect(projection.crossTrackDistance < 0.5)
    }
}

struct OffTrackMonitorTests {
    private let projector = TraceProjector(trackPoints: straightTrace)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func projection(cross: Double, along: Double = 500) -> TraceProjection {
        TraceProjection(distanceAlong: along, crossTrackDistance: cross, segmentIndex: 4)
    }

    private func update(
        _ monitor: inout OffTrackMonitor, cross: Double, along: Double = 500, accuracy: Double = 10,
        at seconds: TimeInterval
    ) -> OffTrackMonitor.Status {
        monitor.update(
            projection: projection(cross: cross, along: along), horizontalAccuracy: accuracy,
            traceLength: 1000, timestamp: start.addingTimeInterval(seconds))
    }

    @Test func firstFixAdoptsStateImmediately() {
        var monitor = OffTrackMonitor()
        #expect(update(&monitor, cross: 5, at: 0) == .onTrack)
    }

    @Test func singleFarFixDoesNotFlip() {
        var monitor = OffTrackMonitor(dwell: 20)
        _ = update(&monitor, cross: 5, at: 0)
        #expect(update(&monitor, cross: 120, at: 5) == .onTrack)
        #expect(update(&monitor, cross: 4, at: 10) == .onTrack)
    }

    @Test func persistentDriftFlipsAfterDwell() {
        var monitor = OffTrackMonitor(dwell: 20)
        _ = update(&monitor, cross: 5, at: 0)
        _ = update(&monitor, cross: 120, at: 5)
        _ = update(&monitor, cross: 130, at: 15)
        #expect(monitor.status == .onTrack)
        #expect(update(&monitor, cross: 140, at: 26) == .offTrack)
    }

    @Test func hysteresisBandKeepsCurrentState() {
        var monitor = OffTrackMonitor(triggerDistance: 50, clearDistance: 30, dwell: 0)
        _ = update(&monitor, cross: 5, at: 0)
        // 40 m is between clear (30) and trigger (50): stays on-track.
        #expect(update(&monitor, cross: 40, at: 10) == .onTrack)

        _ = update(&monitor, cross: 120, at: 20)
        #expect(monitor.status == .offTrack)
        // Coming back: 40 m is still above clear, stays off-track.
        #expect(update(&monitor, cross: 40, at: 30) == .offTrack)
        #expect(update(&monitor, cross: 10, at: 40) == .onTrack)
    }

    @Test func poorAccuracyRaisesTrigger() {
        var monitor = OffTrackMonitor(triggerDistance: 50, dwell: 0)
        _ = update(&monitor, cross: 5, at: 0)
        // 70 m off with ±40 m accuracy: trigger is 80 m, no alarm.
        #expect(update(&monitor, cross: 70, accuracy: 40, at: 10) == .onTrack)
        // Same 70 m with good accuracy: off-track.
        #expect(update(&monitor, cross: 70, accuracy: 8, at: 20) == .offTrack)
    }

    @Test func farFromStartIsApproachingNotOffTrack() {
        var monitor = OffTrackMonitor(dwell: 0)
        #expect(update(&monitor, cross: 400, along: 0, at: 0) == .approachingStart)
        #expect(update(&monitor, cross: 400, along: 1000, at: 10) == .finished)
    }
}
