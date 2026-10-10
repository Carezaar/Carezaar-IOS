import Foundation
import CoreLocation

/// Both signup forms submit `lat`/`lng`. Android asks for location permission and
/// uses Google Maps; iOS uses CoreLocation for the same functional outcome.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var isResolving = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        status = manager.authorizationStatus
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    func request() {
        isResolving = true
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            status = manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            } else {
                isResolving = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let last = locations.last?.coordinate
        Task { @MainActor in
            coordinate = last
            isResolving = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in isResolving = false }
    }
}
