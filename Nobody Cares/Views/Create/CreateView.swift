//
//  CreateView.swift
//  Nobody Cares
//
//  Full-screen camera capture view.
//
//  Shutter behavior (per spec Section 10.2):
//  - Tap (< 300ms press): capture photo
//  - Hold (>= 300ms press): begin video recording
//  - Circular progress ring fills clockwise (yellow accent, 6s max)
//  - Release or 6s hard cut: stop recording
//
//  Chrome (top bar + tab bar) is hidden during capture.
//  After capture: process media → upload → switch to feed → show banner.
//

import SwiftUI

struct CreateView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionService.self) private var permissionService
    @Environment(AppAttestService.self) private var appAttestService

    @State private var cameraController: CameraPreviewController?
    @State private var isRecording = false
    @State private var recordingProgress: Double = 0.0
    @State private var pressStartTime: Date?
    @State private var recordingTimer: Timer?
    @State private var isProcessing = false
    @State private var showError = false
    @State private var errorMessage: String?
    @State private var uploadTask: Task<Void, Never>?

    private let maxRecordingDuration: TimeInterval = 6.0
    private let tapThreshold: TimeInterval = 0.3

    var body: some View {
        ZStack {
            // Camera viewfinder
            CameraPreviewView(
                onCapture: { result in
                    handleCaptureResult(result)
                },
                onError: { error in
                    handleCaptureError(error)
                },
                controller: $cameraController
            )
            .ignoresSafeArea()

            // Shutter button + cancel overlay
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    shutterButton
                    Spacer()
                }
                .overlay(alignment: .bottomTrailing) {
                    cancelButton
                }
                .padding(.horizontal, NCMetrics.contentPadding)
                .padding(.bottom, 48)
            }

            // Processing overlay
            if isProcessing {
                processingOverlay
            }
        }
        .onAppear {
            appState.isCameraActive = true
            // Start location updates so a fix is cached by capture time
            permissionService.startUpdatingLocation()
            AnalyticsService.shared.track(.cameraOpened)
        }
        .onDisappear {
            appState.isCameraActive = false
            permissionService.stopUpdatingLocation()
            stopRecordingCleanup()
            uploadTask?.cancel()
        }
        .retroDialog(isPresented: $showError) {
            RetroDialog(
                title: "ERROR",
                icon: .caution,
                headline: "CONTENT LOST TO THE VOID",
                body_text: errorMessage ?? "Something went wrong. Your content has been consigned to oblivion.",
                primaryAction: .init(title: "DISMISS") {
                    showError = false
                    errorMessage = nil
                }
            )
        }
    }

    // MARK: - Cancel Button

    private var cancelButton: some View {
        Button {
            appState.selectedTab = .feed
        } label: {
            Text("CANCEL")
                .font(NCFont.body(12))
                .foregroundColor(.white)
                .tracking(0.5)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55))
                .retroBorder(color: Color.white.opacity(0.3), width: 1)
        }
        .buttonStyle(.plain)
        .opacity(isProcessing ? 0 : 1)
        .disabled(isProcessing)
    }

    // MARK: - Shutter Button

    private var shutterButton: some View {
        ZStack {
            // Recording progress ring (behind shutter)
            if isRecording {
                Circle()
                    .trim(from: 0, to: recordingProgress)
                    .stroke(
                        NCColor.accentYellow,
                        style: StrokeStyle(lineWidth: 4, lineCap: .butt)
                    )
                    .frame(width: NCMetrics.shutterOuterSize, height: NCMetrics.shutterOuterSize)
                    .rotationEffect(.degrees(-90))
            }

            // Outer ring
            Circle()
                .stroke(Color.white, lineWidth: NCMetrics.borderWidth)
                .frame(
                    width: NCMetrics.shutterOuterSize,
                    height: NCMetrics.shutterOuterSize
                )

            // Inner circle — white normally, red while recording
            Circle()
                .fill(isRecording ? Color.red : Color.white)
                .frame(
                    width: NCMetrics.shutterSize - 8,
                    height: NCMetrics.shutterSize - 8
                )

            // Inner border
            Circle()
                .stroke(Color.black, lineWidth: NCMetrics.borderWidth)
                .frame(
                    width: NCMetrics.shutterSize - 8,
                    height: NCMetrics.shutterSize - 8
                )
        }
        .frame(width: NCMetrics.shutterOuterSize, height: NCMetrics.shutterOuterSize)
        .opacity(isProcessing ? 0.5 : 1.0)
        .gesture(shutterGesture)
        .disabled(isProcessing)
    }

    // MARK: - Shutter Gesture

    private var shutterGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressStartTime == nil else { return }
                pressStartTime = Date()

                // Start a timer to check if hold exceeds threshold
                recordingTimer = Timer.scheduledTimer(withTimeInterval: tapThreshold, repeats: false) { [self] _ in
                    Task { @MainActor in
                        beginRecording()
                    }
                }
            }
            .onEnded { _ in
                guard let startTime = pressStartTime else { return }
                let pressDuration = Date().timeIntervalSince(startTime)
                pressStartTime = nil

                if pressDuration < tapThreshold {
                    // Tap — capture photo
                    recordingTimer?.invalidate()
                    recordingTimer = nil
                    capturePhoto()
                } else if isRecording {
                    // Release during recording — stop
                    stopRecording()
                }
            }
    }

    // MARK: - Capture Actions

    private func capturePhoto() {
        guard !isProcessing else { return }
        isProcessing = true
        cameraController?.capturePhoto()
    }

    private func beginRecording() {
        guard !isRecording, !isProcessing else { return }
        isRecording = true
        recordingProgress = 0.0
        cameraController?.startRecording()

        // Animate progress ring over 6 seconds
        withAnimation(.linear(duration: maxRecordingDuration)) {
            recordingProgress = 1.0
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        isProcessing = true
        withAnimation(.linear(duration: 0.1)) {
            recordingProgress = 0.0
        }
        cameraController?.stopRecording()
    }

    private func stopRecordingCleanup() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if isRecording {
            cameraController?.stopRecording()
            isRecording = false
        }
    }

    // MARK: - Handle Capture Results

    private func handleCaptureResult(_ result: CaptureResult) {
        uploadTask = Task { @MainActor in
            do {
                // Get current location (10s timeout)
                print("[Upload] Requesting location...")
                guard let location = await permissionService.fetchCurrentLocation() else {
                    throw CaptureError.noLocation
                }
                try Task.checkCancellation()
                print("[Upload] Location acquired: \(location.coordinate), accuracy: \(location.horizontalAccuracy)m")

                // Validate accuracy
                guard location.horizontalAccuracy < 100 else {
                    throw CaptureError.poorAccuracy(location.horizontalAccuracy)
                }

                // Process media
                print("[Upload] Processing media...")
                let processedMedia: ProcessedMedia
                switch result {
                case .photo(let data, _):
                    processedMedia = try MediaProcessor.processPhoto(data: data)
                case .video(let url):
                    processedMedia = try await MediaProcessor.processVideo(url: url)
                }
                try Task.checkCancellation()
                print("[Upload] Media processed: \(processedMedia.contentType.rawValue), \(processedMedia.fileSizeBytes) bytes")

                // Upload
                print("[Upload] Starting upload pipeline...")
                try await UploadService.shared.upload(
                    media: processedMedia,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracy: location.horizontalAccuracy,
                    appAttest: appAttestService
                )
                print("[Upload] Upload complete!")

                // Success — switch to feed, show banner
                AnalyticsService.shared.track(.contentCreated, metadata: [
                    "type": processedMedia.contentType.rawValue,
                ])
                isProcessing = false
                appState.selectedTab = .feed
                withAnimation(.linear(duration: 0.15)) {
                    appState.showArchivedBanner = true
                }
            } catch is CancellationError {
                print("[Upload] Cancelled by user")
                isProcessing = false
            } catch {
                print("[Upload] Failed: \(error)")
                isProcessing = false
                errorMessage = mapCaptureError(error)
                showError = true
                AnalyticsService.shared.track(.uploadFailed, metadata: [
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func handleCaptureError(_ error: String) {
        Task { @MainActor in
            isProcessing = false
            isRecording = false
            errorMessage = error
            showError = true
        }
    }

    // MARK: - Error Mapping

    private func mapCaptureError(_ error: Error) -> String {
        if let captureError = error as? CaptureError {
            switch captureError {
            case .noLocation:
                AnalyticsService.shared.track(.locationUnavailable)
                return "NO SIGNAL. CONTENT IS PATIENT. Move to a location with GPS signal and try again."
            case .poorAccuracy(let accuracy):
                AnalyticsService.shared.track(.gpsInaccurate, metadata: ["accuracy": String(Int(accuracy))])
                return "GPS ACCURACY INSUFFICIENT (\(Int(accuracy))m). Move to an open area for better signal. Required: < 100m accuracy."
            case .fileTooLarge:
                return "CONTENT TOO LARGE. Maximum file size is 50MB. Try a shorter recording."
            case .processingFailed:
                return "CONTENT PROCESSING FAILED. The media could not be prepared for upload."
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            AnalyticsService.shared.track(.networkError, metadata: ["code": String((error as NSError).code)])
            return "NO SIGNAL. CONTENT IS PATIENT. Check your connection and try again."
        }
        return "CONTENT LOST TO THE VOID. \(error.localizedDescription)"
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                PixelIcon(type: .hourglass, size: 32, color: .white)

                Text("ARCHIVING CONTENT...")
                    .font(NCFont.display(14))
                    .foregroundColor(.white)
                    .tracking(1)

                Button {
                    uploadTask?.cancel()
                    uploadTask = nil
                    isProcessing = false
                } label: {
                    Text("CANCEL")
                        .font(NCFont.display(12))
                        .foregroundColor(NCColor.accentYellow)
                        .tracking(1)
                        .padding(.top, 8)
                }
            }
        }
    }
}

// MARK: - Capture Errors

enum CaptureError: Error {
    case noLocation
    case poorAccuracy(Double)
    case fileTooLarge
    case processingFailed
}

#Preview("Create View") {
    CreateView()
        .environment(AppState())
        .environment(AuthService())
        .environment(PermissionService())
}
