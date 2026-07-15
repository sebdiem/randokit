import CoreLocation
import Foundation
import RandoKit

struct TappedPointInfo: Equatable {
    let km: Double
    let elevation: Double
    let latitude: Double
    let longitude: Double
    let name: String?
    var category: Waypoint.Category = .standard
}

/// Main-screen navigation state and transitions. SwiftUI renders this snapshot;
/// geospatial decisions no longer live in view callbacks.
@MainActor
final class NavigationSession: ObservableObject {
    @Published private(set) var active: TraceLibrary.Active?
    @Published private(set) var currentProjection: TraceProjection?
    @Published private(set) var offTrackStatus: OffTrackMonitor.Status = .unknown
    @Published private(set) var selectionCoordinateSegments: [[CLLocationCoordinate2D]] = []
    @Published private(set) var tappedPoint: TappedPointInfo?
    @Published var visibleKmRange: ClosedRange<Double>?
    @Published var selectedKmRange: ClosedRange<Double>? {
        didSet { rebuildSelectionCoordinates() }
    }

    private var monitor = OffTrackMonitor()

    func activate(_ active: TraceLibrary.Active?, lastFix: CLLocation?) {
        let dwell = monitor.dwell
        monitor = OffTrackMonitor(dwell: dwell)
        offTrackStatus = .unknown
        currentProjection = nil
        selectedKmRange = nil
        selectionCoordinateSegments = []
        visibleKmRange = nil
        tappedPoint = nil
        self.active = active
        handle(lastFix)
    }

    func setOffTrackDwell(_ dwell: TimeInterval) {
        monitor.dwell = dwell
    }

    func handle(_ fix: CLLocation?) {
        guard let fix, let projector = active?.projector,
            let projection = projector.project(
                latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                nearSegment: currentProjection?.segmentIndex)
        else { return }
        offTrackStatus = monitor.update(
            projection: projection, horizontalAccuracy: fix.horizontalAccuracy,
            traceLength: projector.totalDistance, timestamp: fix.timestamp)
        currentProjection = projection
    }

    /// Resolves a map tap: nearby waypoint first, otherwise a trace snap.
    func handleMapTap(_ coordinate: CLLocationCoordinate2D, thresholdMeters: Double) {
        guard let active else { return }
        let tapPoint = TrackPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let nearestMark = active.waypointMarks
            .map { mark in
                (
                    mark,
                    Geo.distanceMeters(
                        from: tapPoint,
                        to: TrackPoint(latitude: mark.latitude, longitude: mark.longitude))
                )
            }
            .min { $0.1 < $1.1 }
        if let (mark, distance) = nearestMark, distance < max(thresholdMeters, 60) {
            tappedPoint = TappedPointInfo(
                km: mark.km,
                elevation: active.linearized.elevation(atDistance: mark.km * 1000) ?? 0,
                latitude: mark.latitude, longitude: mark.longitude,
                name: mark.name,
                category: mark.category)
            return
        }

        guard
            let projection = active.projector.project(
                latitude: coordinate.latitude, longitude: coordinate.longitude),
            projection.crossTrackDistance < thresholdMeters,
            let snapped = active.projector.coordinate(atDistance: projection.distanceAlong)
        else {
            tappedPoint = nil
            return
        }
        tappedPoint = TappedPointInfo(
            km: projection.distanceAlong / 1000,
            elevation: active.linearized.elevation(atDistance: projection.distanceAlong) ?? 0,
            latitude: snapped.latitude, longitude: snapped.longitude,
            name: nil)
    }

    /// Resolves a tap on the profile and adopts a nearby waypoint's metadata.
    func selectPoint(atKm km: Double) {
        guard let active,
            let elevation = active.linearized.elevation(atDistance: km * 1000),
            let coordinate = active.projector.coordinate(atDistance: km * 1000)
        else { return }
        let nearbyMark = active.waypointMarks
            .filter { abs($0.km - km) < 0.15 }
            .min { abs($0.km - km) < abs($1.km - km) }
        tappedPoint = TappedPointInfo(
            km: km, elevation: elevation,
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            name: nearbyMark?.name,
            category: nearbyMark?.category ?? .standard)
    }

    func clearTappedPoint() {
        tappedPoint = nil
    }

    private func rebuildSelectionCoordinates() {
        guard let projector = active?.projector, let kmRange = selectedKmRange else {
            selectionCoordinateSegments = []
            return
        }
        var slices = projector.sliceCoordinateSegments(
            in: (kmRange.lowerBound * 1000)...(kmRange.upperBound * 1000))

        // Keep drag updates bounded regardless of GPX density. Budgets are
        // proportional per real segment so no artificial connector is created.
        let maxOverlayPoints = 800
        let totalPointCount = slices.reduce(0) { $0 + $1.count }
        if totalPointCount > maxOverlayPoints {
            slices = slices.map { slice in
                let budget = max(
                    2,
                    Int(
                        (Double(slice.count) / Double(totalPointCount)
                            * Double(maxOverlayPoints)).rounded()))
                guard slice.count > budget, let last = slice.last else { return slice }
                let stride = Double(slice.count - 1) / Double(budget - 1)
                var reduced = (0..<(budget - 1)).map { slice[Int(Double($0) * stride)] }
                reduced.append(last)
                return reduced
            }
        }
        selectionCoordinateSegments = slices.map { slice in
            slice.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }
}
