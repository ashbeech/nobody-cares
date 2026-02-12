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

    /// Effective search radius — accounts for GPS uncertainty on *both* sides.
    ///
    /// Two independent GPS readings are involved in a proximity check:
    ///   1. The content's capture position (recorded at creation time)
    ///   2. The viewer's current position (read at query time)
    ///
    /// Each can be off by its `horizontalAccuracy`. With typical 7-10m accuracy,
    /// two readings can compound to 15-20m of drift — easily pushing content
    /// outside a 10m radius even though the user hasn't moved.
    ///
    /// Formula: baseRadius + 2 × viewerAccuracy  (conservative estimate that
    /// captures both sides, since we don't have the capture accuracy at query time).
    /// Floor of 30m ensures stability even with excellent GPS.
    var effectiveRadius: Double {
        let baseRadius: Double = 10.0
        let minimumRadius: Double = 30.0
        guard let location = currentLocation else { return minimumRadius }
        return max(minimumRadius, baseRadius + location.horizontalAccuracy * 2)
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

    private let movementThreshold: Double = 10.0      // meters (above GPS noise floor; typical jitter is 5-7m)
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

        // Check if we've moved far enough from last query to warrant a new one
        if let lastQuery = lastQueryLocation {
            let distanceFromLastQuery = current.distance(from: lastQuery)
            if distanceFromLastQuery >= movementThreshold {
                FeedDebugLogger.log(.loc, "significantMovement — \(String(format: "%.1f", distanceFromLastQuery))m from last query → re-querying")
                lastQueryLocation = current
                onSignificantMovement?()
            } else {
                FeedDebugLogger.log(.loc, "movement — \(String(format: "%.1f", distanceFromLastQuery))m from last query (below threshold)")
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
                guard let self else { return }
                if self.movementState == .moving {
                    FeedDebugLogger.log(.loc, "⏱ periodicQuery — \(self.queryInterval)s timer fired (state=moving)")
                    self.onSignificantMovement?()
                }
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
