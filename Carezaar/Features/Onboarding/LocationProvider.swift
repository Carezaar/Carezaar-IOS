import Foundation
import CoreLocation
#if DEBUG
import CryptoKit
#endif

/// Uses a genuine cached phone fix immediately, then requests a newer fix.
/// A stale cached fix remains usable silently as the initial map position.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var lastKnownIsStale = false
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isResolving = false

    private lazy var manager = CLLocationManager()
    private var requested = false
    #if DEBUG
    private let qaFixture = QALocationFixture.launched
    private var qaDelivery: Task<Void, Never>?
    private var qaManualSelectionSeen = false
    private var qaManualSelectionCount = 0
    private var qaManualSelectionDigest = "none"
    private let qaProviderID = String(UUID().uuidString.prefix(8))
    #endif

    override init() {
        super.init()
        #if DEBUG
        if let qaFixture {
            // Controlled QA never reads cached GPS, constructs the real manager,
            // or asks for permission. This is synthetic input, not physical proof.
            status = qaFixture.mode == "none" ? .denied : .authorizedWhenInUse
            if qaFixture.mode == "available" || qaFixture.mode == "stale" {
                deliverQAFixture(qaFixture, phase: "cached")
            }
            return
        }
        #endif
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        status = manager.authorizationStatus
        useLastKnownLocation()
    }

    nonisolated static func usableCoordinate(from location: CLLocation?) -> CLLocationCoordinate2D? {
        guard let location, location.horizontalAccuracy >= 0,
              location.timestamp.timeIntervalSinceNow <= 60 else { return nil }
        return initialMapCoordinate(location.coordinate)
    }

    nonisolated static func initialMapCoordinate(_ initial: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        guard let initial, initial.latitude.isFinite, initial.longitude.isFinite,
              CLLocationCoordinate2DIsValid(initial) else { return nil }
        return initial
    }

    nonisolated static func isStale(_ location: CLLocation, now: Date = Date()) -> Bool {
        now.timeIntervalSince(location.timestamp) > 300
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    private func useLastKnownLocation() {
        guard status == .authorizedWhenInUse || status == .authorizedAlways,
              let cached = manager.location, let valid = Self.usableCoordinate(from: cached) else { return }
        coordinate = valid
        lastKnownIsStale = Self.isStale(cached)
    }

    func request() {
        #if DEBUG
        if let qaFixture {
            guard !isResolving else { return }
            requested = true
            isResolving = true
            qaDelivery?.cancel()
            qaDelivery = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, requested else { return }
                deliverQAFixture(qaFixture, phase: qaFixture.mode == "late-valid" ? "waiting-manual" : "delivery")
            }
            return
        }
        #endif
        useLastKnownLocation()
        guard !isResolving, !isDenied else { return }
        requested = true
        isResolving = true
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestLocation()
        }
    }

    func cancel() {
        requested = false
        #if DEBUG
        qaDelivery?.cancel()
        qaDelivery = nil
        if qaFixture == nil { manager.stopUpdatingLocation() }
        #else
        manager.stopUpdatingLocation()
        #endif
        isResolving = false
    }

    #if DEBUG
    /// Called only after MapKit reports a genuine user-positioned camera.
    func qaManualMapSelectionOccurred(_ center: CLLocationCoordinate2D) {
        guard let qaFixture, qaFixture.mode == "late-valid", requested,
              let digest = QALocationFixture.displayDigest(for: center) else { return }
        qaManualSelectionCount += 1
        qaManualSelectionDigest = digest
        QARequestLedger.shared.recordLocationFixture(
            "provider=\(qaProviderID) mode=late-valid phase=manual-position manualCount=\(qaManualSelectionCount) selectedDigest=\(digest)")
        guard !qaManualSelectionSeen else { return }
        qaManualSelectionSeen = true
        QARequestLedger.shared.recordLocationFixture(
            "provider=\(qaProviderID) mode=late-valid phase=manual-pan accepted=false stale=false manualCount=\(qaManualSelectionCount) selectedDigest=\(digest)")
        qaDelivery?.cancel()
        qaDelivery = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled, requested else { return }
            deliverQAFixture(qaFixture, phase: "late-after-manual")
        }
    }

    private func deliverQAFixture(_ fixture: QALocationFixture, phase: String) {
        let fix = fixture.location(late: phase == "late-after-manual")
        let accepted = Self.usableCoordinate(from: fix)
        if let fix, let accepted {
            coordinate = accepted
            lastKnownIsStale = Self.isStale(fix)
        }
        isResolving = false
        QARequestLedger.shared.recordLocationFixture(
            "provider=\(qaProviderID) mode=\(fixture.mode) phase=\(phase) accepted=\(accepted != nil) stale=\(lastKnownIsStale) manualCount=\(qaManualSelectionCount) selectedDigest=\(qaManualSelectionDigest)")
    }
    #endif

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            status = manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                useLastKnownLocation()
                if requested { manager.requestLocation() }
            } else if status == .denied || status == .restricted {
                requested = false
                isResolving = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.reversed().first { Self.usableCoordinate(from: $0) != nil }
        Task { @MainActor in
            guard requested else { return }
            if let latest, let valid = Self.usableCoordinate(from: latest) {
                coordinate = valid
                lastKnownIsStale = Self.isStale(latest)
            }
            isResolving = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in isResolving = false }
    }
}

#if DEBUG
/// Synthetic input configuration; all filtering remains in LocationProvider's
/// actual usableCoordinate/isStale path, including delayed map delivery.
struct QALocationFixture {
    let mode: String
    static let launched: QALocationFixture? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-location-fixture"), i + 1 < args.count else { return nil }
        return QALocationFixture(mode: args[i + 1])
    }()
    init?(mode: String) {
        guard ["available", "stale", "negative-accuracy", "out-of-range", "future", "none", "late-valid"].contains(mode) else { return nil }
        self.mode = mode
    }
    static func displayDigest(for coordinate: CLLocationCoordinate2D) -> String? {
        guard LocationProvider.initialMapCoordinate(coordinate) != nil else { return nil }
        let displayed = String(format: "%.6f , %.6f", coordinate.latitude, coordinate.longitude)
        return SHA256.hash(data: Data(displayed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func location(late: Bool = false, now: Date = Date()) -> CLLocation? {
        guard mode != "none", mode != "late-valid" || late else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: mode == "out-of-range" ? 91 : 39.8283, longitude: -98.5795)
        let age: TimeInterval = mode == "stale" ? -3_600 : mode == "future" ? 3_600 : 0
        return CLLocation(coordinate: coordinate, altitude: 0,
                          horizontalAccuracy: mode == "negative-accuracy" ? -1 : 20,
                          verticalAccuracy: -1, timestamp: now.addingTimeInterval(age))
    }
}
#endif
