//
//  LocationService.swift
//  Nobody Cares
//
//  Advanced location management for the feed system.
//
//  Behaviors (per spec Section 6):
//  - kCLLocationAccuracyBest, distanceFilter: 5.0
//  - Movement detection: re-query feed when moved >5m or every 15s while moving
//  - Stationary detection: after 30s without significant movement, switch to
//    Realtime subscription mode (less battery, server-pushed updates)
//  - Simulated location detection via CLLocation.sourceInformation
//  - Low-accuracy fallback: widen effective radius
//

import CoreLocation
import Combine

// MARK: - Movement State

enum MovementState: Equatable {
    case unknown
    case moving
    case stationary
}

// MARK: - Location Service

@Observable
final class LocationService {
    // MARK: - Published State

    var currentLocation: CLLocation?
    var movementState: MovementState = .unknown
    var isSimulatedLocation = false
    var isLowAccuracy = false

    /// Effective search radius — widened when accuracy is poor.
    ///
    /// With GPS accuracy of X meters, the reported position can be up to X m
    /// from reality.  A 10 m radius centred on a position that's 30 m off
    /// won't intersect the user's actual location at all.
    ///
    /// Scaling to `accuracy × 2` gives ≈95 % confidence the search circle
    /// covers the real position, while keeping the radius tight (10 m) when
    /// the fix is good (≤ 5 m accuracy).  Capped at 100 m.
    var effectiveRadius: Double {
        guard let location = currentLocation else { return 10.0 }
        return min(100.0, max(10.0, location.horizontalAccuracy * 2.0))
    }

    // MARK: - Callbacks

    var onSignificantMovement: (() -> Void)?
    var onBecameStationary: (() -> Void)?

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private let delegate = LocationServiceDelegate()
    private var lastQueryLocation: CLLocation?
    private var lastMovementTime: Date = .now
    private var stationaryTimer: Timer?
    private var periodicQueryTimer: Timer?

    private let movementThreshold: Double = 5.0       // meters
    private let queryInterval: TimeInterval = 15.0     // seconds (while moving)
    private let stationaryDelay: TimeInterval = 30.0   // seconds without movement

    // MARK: - Init

    init() {
        locationManager.delegate = delegate
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5.0

        delegate.onLocationUpdate = { [weak self] locations in
            guard let self, let location = locations.last else { return }
            self.processLocationUpdate(location)
        }
    }

    // MARK: - Start / Stop

    func startMonitoring() {
        FeedDebugLogger.log(.loc, "startMonitoring")
        locationManager.startUpdatingLocation()
        startPeriodicQueryTimer()
    }

    func stopMonitoring() {
        FeedDebugLogger.log(.loc, "stopMonitoring")
        locationManager.stopUpdatingLocation()
        stationaryTimer?.invalidate()
        stationaryTimer = nil
        periodicQueryTimer?.invalidate()
        periodicQueryTimer = nil
    }

    // MARK: - Location Processing

    private func processLocationUpdate(_ location: CLLocation) {
        // Check for simulated location (iOS 15+)
        if let sourceInfo = location.sourceInformation {
            isSimulatedLocation = sourceInfo.isSimulatedBySoftware || sourceInfo.isProducedByAccessory
        }

        // Check accuracy
        isLowAccuracy = location.horizontalAccuracy > 50

        let previousLocation = currentLocation
        currentLocation = location

        // Check for significant movement
        if let previous = previousLocation {
            let distance = location.distance(from: previous)
            if distance >= movementThreshold {
                FeedDebugLogger.log(.loc, "📍 movement detected: \(String(format: "%.1f", distance))m",
                                    detail: "lat=\(String(format: "%.6f", location.coordinate.latitude)) lng=\(String(format: "%.6f", location.coordinate.longitude)) acc=\(String(format: "%.1f", location.horizontalAccuracy))m")
                handleMovement(from: previous, to: location)
            }
        } else {
            // First location fix
            FeedDebugLogger.log(.loc, "📍 FIRST location fix",
                                detail: "lat=\(String(format: "%.6f", location.coordinate.latitude)) lng=\(String(format: "%.6f", location.coordinate.longitude)) acc=\(String(format: "%.1f", location.horizontalAccuracy))m")
            lastQueryLocation = location
            movementState = .unknown
            onSignificantMovement?()
        }
    }

    private func handleMovement(from previous: CLLocation, to current: CLLocation) {
        lastMovementTime = .now
        movementState = .moving

        // Reset stationary timer
        stationaryTimer?.invalidate()
        stationaryTimer = Timer.scheduledTimer(withTimeInterval: stationaryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleBecameStationary()
            }
        }

        // Check if we've moved far enough from last query to warrant a new one.
        // GPS jitter filter: require the distance to exceed the combined accuracy
        // of both readings.  Without this, a static device with 5 m accuracy
        // continuously reports 5-9 m of "movement", triggering re-queries that
        // swap feed content in and out.
        if let lastQuery = lastQueryLocation {
            let distanceFromLastQuery = current.distance(from: lastQuery)
            let accuracyFloor = lastQuery.horizontalAccuracy + current.horizontalAccuracy
            let effectiveThreshold = max(movementThreshold, accuracyFloor)
            if distanceFromLastQuery >= effectiveThreshold {
                FeedDebugLogger.log(.loc, "significantMovement — \(String(format: "%.1f", distanceFromLastQuery))m from last query (threshold=\(String(format: "%.1f", effectiveThreshold))m) → re-querying")
                lastQueryLocation = current
                onSignificantMovement?()
            } else {
                FeedDebugLogger.log(.loc, "movement — \(String(format: "%.1f", distanceFromLastQuery))m from last query (below accuracy-aware threshold \(String(format: "%.1f", effectiveThreshold))m)")
            }
        } else {
            FeedDebugLogger.log(.loc, "significantMovement — first query location set")
            lastQueryLocation = current
            onSignificantMovement?()
        }
    }

    private func handleBecameStationary() {
        FeedDebugLogger.log(.loc, "🧍 becameStationary — no movement for \(stationaryDelay)s")
        movementState = .stationary
        onBecameStationary?()
    }

    // MARK: - Periodic Query Timer

    private func startPeriodicQueryTimer() {
        periodicQueryTimer = Timer.scheduledTimer(withTimeInterval: queryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.movementState == .moving else { return }

                // Same accuracy-aware gate as handleMovement: don't re-query
                // if we haven't genuinely moved since the last query.
                if let current = self.currentLocation, let lastQuery = self.lastQueryLocation {
                    let distance = current.distance(from: lastQuery)
                    let accuracyFloor = lastQuery.horizontalAccuracy + current.horizontalAccuracy
                    let effectiveThreshold = max(self.movementThreshold, accuracyFloor)
                    guard distance >= effectiveThreshold else {
                        FeedDebugLogger.log(.loc, "⏱ periodicQuery — \(self.queryInterval)s timer fired but \(String(format: "%.1f", distance))m < accuracy-aware threshold \(String(format: "%.1f", effectiveThreshold))m → skipping")
                        return
                    }
                    FeedDebugLogger.log(.loc, "⏱ periodicQuery — \(self.queryInterval)s timer fired, \(String(format: "%.1f", distance))m from last query → re-querying")
                    self.lastQueryLocation = current
                } else {
                    FeedDebugLogger.log(.loc, "⏱ periodicQuery — \(self.queryInterval)s timer fired (state=moving)")
                }
                self.onSignificantMovement?()
            }
        }
    }

    // MARK: - Manual Location Fetch

    func fetchCurrentLocation() async -> CLLocation? {
        if let location = currentLocation, location.timestamp.timeIntervalSinceNow > -10 {
            return location
        }
        // Delegate is already set up; just wait for the next update
        return await withCheckedContinuation { continuation in
            delegate.oneShotContinuation = continuation
            locationManager.requestLocation()
        }
    }
}

// MARK: - Location Service Delegate

private class LocationServiceDelegate: NSObject, CLLocationManagerDelegate {
    var onLocationUpdate: (([CLLocation]) -> Void)?
    var oneShotContinuation: CheckedContinuation<CLLocation?, Never>?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocationUpdate?(locations)

        if let continuation = oneShotContinuation {
            continuation.resume(returning: locations.last)
            oneShotContinuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let continuation = oneShotContinuation {
            continuation.resume(returning: nil)
            oneShotContinuation = nil
        }
    }
}
