// The phone's own location, from Core Location, for the node to share: the node rounds it to each
// destination's precision before anything goes on the air. Only the model starts it, and only while
// the node shares with someone; the map's blue dot is MapKit's own.
//
// Everything runs on the main queue, as the Bluetooth link does: the manager is made there, and
// Core Location calls its delegate back on the thread it was made on.

import CoreLocation
import Foundation

final class LocationFeed: NSObject, CLLocationManagerDelegate {
    /// Each location Core Location gives while the feed runs.
    var onFix: (CLLocation) -> Void = { _ in }
    /// The user allowed or refused the app their location, or changed their mind in Settings.
    var onAuthorization: () -> Void = {}

    private let manager = CLLocationManager()
    private(set) var isRunning = false

    override init() {
        super.init()
        manager.delegate = self
        // Updates as often as Core Location has them: a node standing still still needs a fresh fix,
        // or it stops sharing a stale one. The model sends at most one each `NodeModel.fixEvery`.
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// The user has not yet been asked.
    var isUndecided: Bool { manager.authorizationStatus == .notDetermined }

    /// Allowed, while the app is in use or always. When in use is enough: updates begun in front
    /// go on in the background.
    var isAllowed: Bool {
        switch manager.authorizationStatus {
        case .notDetermined, .restricted, .denied: return false
        default: return true
        }
    }

    /// The last location Core Location has, from this app or not, if any.
    var last: CLLocation? { isAllowed ? manager.location : nil }

    /// Asks the user, once: only when they turn sharing on, never before.
    func ask() {
        guard isUndecided else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Starts updates, or changes how exact they are. `fine` for a destination shared with at
    /// precision 20 or more, a street or finer; a neighbourhood or coarser does not need the GPS.
    func start(fine: Bool) {
        guard isAllowed else { return }
        manager.desiredAccuracy = fine ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        if isRunning { return }
        isRunning = true
        #if os(iOS)
        // Sharing means the phone is in a pocket. Only while running: the blue pill says so.
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        #endif
        manager.startUpdatingLocation()
    }

    /// Asks for updates again if running. Begun in the background, as when iOS relaunches the app
    /// for the node's link, updates under when-in-use permission do not start; in front they do.
    func renew() {
        guard isRunning, isAllowed else { return }
        manager.startUpdatingLocation()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        #endif
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !isAllowed { stop() }
        onAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning, let fix = locations.last else { return }
        onFix(fix)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix for now: the node goes on with its own receiver's, if it has one, and Core
        // Location keeps trying.
    }
}
