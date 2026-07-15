import CoreLocation
import Foundation

/// Foreground-only Core Location wrapper. Publishes fixes that pass the
/// gating rules (valid, reasonably accurate, fresh); everything downstream
/// can trust what it receives.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var lastFix: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 5
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        let accepted = locations.last { fix in
            fix.horizontalAccuracy > 0
                && fix.horizontalAccuracy <= 50
                && fix.timestamp.timeIntervalSinceNow > -15
        }
        guard let accepted else { return }
        Task { @MainActor in
            self.lastFix = accepted
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
