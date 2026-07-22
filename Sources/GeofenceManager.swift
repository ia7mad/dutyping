import Foundation
import CoreLocation

/// Watches a single circular region around the workplace.
///
/// Region monitoring is what makes the location trigger worth having: iOS wakes
/// the app for a crossing even if it has been terminated, so the reminder still
/// arrives.
final class GeofenceManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = GeofenceManager()

    private static let regionID = "workplace"

    private let manager = CLLocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isMonitoring = false
    /// Filled in by "Use my current location"; cleared once consumed.
    @Published var capturedLocation: CLLocationCoordinate2D?

    /// Kept so region callbacks know the current nag preferences.
    private var settings = Settings()

    private override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = false
        authorizationStatus = manager.authorizationStatus
    }

    func requestAuthorization() {
        // Always-authorization can only be requested after when-in-use on iOS,
        // and the system may show it as a follow-up prompt later regardless.
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestAlwaysAuthorization()
        }
    }

    func captureCurrentLocation() {
        manager.requestLocation()
    }

    /// Rebuilds monitoring to match the saved settings.
    func apply(settings: Settings) {
        self.settings = settings

        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        isMonitoring = false

        guard settings.geofenceEnabled,
              let latitude = settings.geofenceLatitude,
              let longitude = settings.geofenceLongitude,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radius: min(settings.geofenceRadius, manager.maximumRegionMonitoringDistance),
            identifier: Self.regionID)
        region.notifyOnEntry = true
        region.notifyOnExit = true

        manager.startMonitoring(for: region)
        isMonitoring = true
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authorizationStatus = status
        if status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        capturedLocation = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed one-off fix just leaves the field empty; nothing to recover.
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        Scheduler.shared.fireNow(kind: .checkIn, reason: "Arrived at work", settings: settings)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        Scheduler.shared.fireNow(kind: .checkOut, reason: "Left work", settings: settings)
    }
}
