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

    /// Request a one-shot location fix. Returns when location is available or fails.
    func fetchCurrentLocation() async -> CLLocation? {
        return await withCheckedContinuation { continuation in
            locationDelegate.oneShotContinuation = continuation
            locationManager.requestLocation()
        }
    }

    /// Start continuous location updates (for feed proximity checks)
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
    var oneShotContinuation: CheckedContinuation<CLLocation?, Never>?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

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
