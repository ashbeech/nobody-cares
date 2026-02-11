//
//  PermissionService.swift
//  Nobody Cares
//
//  Wraps CLLocationManager + AVCaptureDevice permissions.
//  Provides observable permission states and one-shot location fetch.
//

import AVFoundation
import CoreLocation
import SwiftUI

@Observable
final class PermissionService {
    // MARK: - State

    var locationStatus: CLAuthorizationStatus
    var cameraStatus: AVAuthorizationStatus
    var microphoneStatus: AVAuthorizationStatus
    var currentLocation: CLLocation?

    var isLocationAuthorized: Bool {
        locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways
    }

    var isCameraAuthorized: Bool {
        cameraStatus == .authorized
    }

    var isMicrophoneAuthorized: Bool {
        microphoneStatus == .authorized
    }

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private let locationDelegate = LocationManagerDelegate()

    // MARK: - Init

    init() {
        self.locationStatus = CLLocationManager().authorizationStatus
        self.cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        self.microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        locationManager.delegate = locationDelegate
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5.0

        locationDelegate.onAuthorizationChange = { [weak self] status in
            Task { @MainActor in
                self?.locationStatus = status
            }
        }

        locationDelegate.onLocationUpdate = { [weak self] locations in
            Task { @MainActor in
                self?.currentLocation = locations.last
            }
        }
    }

    // MARK: - Permission Requests

    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func requestCameraPermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run {
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
        return granted
    }

    func requestMicrophonePermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        return granted
    }

    // MARK: - Location Fetch

    /// Returns the best available location:
    /// 1. If a recent cached fix exists (< 30s old), returns it immediately.
    /// 2. Otherwise requests a fresh fix with a timeout.
    /// Returns nil only if no location can be obtained at all.
    func fetchCurrentLocation(timeout: TimeInterval = 10) async -> CLLocation? {
        // 1. Use our own cached location if it's fresh enough (< 30 seconds old)
        if let cached = currentLocation,
           abs(cached.timestamp.timeIntervalSinceNow) < 30 {
            print("[Location] Using cached location (age: \(String(format: "%.1f", abs(cached.timestamp.timeIntervalSinceNow)))s)")
            return cached
        }

        // 2. Check system-level cached location (from other apps, often available)
        if let systemCached = locationManager.location,
           abs(systemCached.timestamp.timeIntervalSinceNow) < 60,
           systemCached.horizontalAccuracy >= 0,
           systemCached.horizontalAccuracy < 200 {
            print("[Location] Using system-cached location (age: \(String(format: "%.1f", abs(systemCached.timestamp.timeIntervalSinceNow)))s, accuracy: \(String(format: "%.1f", systemCached.horizontalAccuracy))m)")
            currentLocation = systemCached
            return systemCached
        }

        print("[Location] No recent cache, requesting fresh fix (timeout: \(timeout)s)...")

        // Request a fresh fix with timeout
        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()

            func resumeOnce(with location: CLLocation?) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: location)
            }

            // Timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                print("[Location] Timeout after \(timeout)s")
                resumeOnce(with: nil)
            }

            // Store a callback for when location arrives
            locationDelegate.oneShotCallback = { location in
                print("[Location] Fresh fix received")
                resumeOnce(with: location)
            }

            locationManager.requestLocation()
        }
    }

    /// Start continuous location updates (call when camera opens
    /// so a cached fix is ready by capture time).
    func startUpdatingLocation() {
        locationManager.startUpdatingLocation()
    }

    /// Stop continuous location updates
    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }
}

// MARK: - CLLocationManager Delegate

/// Separate NSObject delegate to avoid @Observable + NSObject conflict.
private class LocationManagerDelegate: NSObject, CLLocationManagerDelegate {
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onLocationUpdate: (([CLLocation]) -> Void)?
    /// One-shot callback for fetchCurrentLocation — cleared after first call.
    var oneShotCallback: ((CLLocation?) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocationUpdate?(locations)

        if let callback = oneShotCallback {
            oneShotCallback = nil
            callback(locations.last)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Location] didFailWithError: \(error.localizedDescription)")
        if let callback = oneShotCallback {
            oneShotCallback = nil
            callback(nil)
        }
    }
}
