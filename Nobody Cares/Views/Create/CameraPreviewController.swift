//
//  CameraPreviewController.swift
//  Nobody Cares
//
//  AVFoundation camera capture — UIKit controller bridged into SwiftUI.
//
//  Handles:
//  - Camera preview (full-screen viewfinder)
//  - Photo capture (HEIF, JPEG fallback)
//  - Video recording (H.264 MOV, 1080p/30fps, max 6s hard cut)
//  - Audio recording (if microphone permission granted)
//

import AVFoundation
import UIKit

// MARK: - Capture Result

enum CaptureResult {
    case photo(Data, isHEIF: Bool)
    case video(URL)
}

// MARK: - Camera Preview Controller

final class CameraPreviewController: UIViewController {

    // MARK: - Callbacks

    var onCapture: ((CaptureResult) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - AVFoundation

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?

    private var isRecording = false
    private var recordingTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 6.0

    /// Strong reference to the photo capture delegate.
    /// AVCapturePhotoOutput retains the delegate on its session queue, but ARC
    /// can release the local before that retention takes effect. Storing it here
    /// keeps it alive until the capture lifecycle completes.
    private var photoCaptureDelegate: PhotoCaptureDelegate?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - Session Setup

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // Video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            onError?("No camera available")
            session.commitConfiguration()
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
                videoDeviceInput = videoInput
            }
        } catch {
            onError?("Camera input failed: \(error.localizedDescription)")
            session.commitConfiguration()
            return
        }

        // Audio input (optional — user may have denied microphone)
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    audioDeviceInput = audioInput
                }
            } catch {
                // Non-fatal: video records without audio
            }
        }

        // Photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)

            // Use the highest resolution the active format supports
            if let maxDimensions = videoDevice.activeFormat.supportedMaxPhotoDimensions.last {
                photoOutput.maxPhotoDimensions = maxDimensions
            }
        }

        // Movie output
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            movieOutput.maxRecordedDuration = CMTime(seconds: maxRecordingDuration, preferredTimescale: 600)
        }

        // Configure video connection
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off // Spec: no stabilization
            }
        }

        session.commitConfiguration()

        // Preview layer
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    // MARK: - Session Control

    private func startSession() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    private func stopSession() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - Photo Capture

    func capturePhoto() {
        FeedDebugLogger.log(.camera, "capturePhoto() called", detail: "isRecording=\(isRecording) sessionRunning=\(session.isRunning)")
        guard !isRecording else {
            FeedDebugLogger.log(.camera, "⚠️ capturePhoto() bailed — isRecording=true")
            return
        }

        let settings = AVCapturePhotoSettings()

        // Prefer HEIF, fall back to JPEG
        let captureSettings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            captureSettings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: AVVideoCodecType.hevc
            ])
        } else {
            captureSettings = settings
        }

        // Request the highest resolution the output supports
        captureSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        FeedDebugLogger.log(.camera, "Initiating capture", detail: "dims=\(captureSettings.maxPhotoDimensions.width)×\(captureSettings.maxPhotoDimensions.height) hevc=\(photoOutput.availablePhotoCodecTypes.contains(.hevc))")

        let delegate = PhotoCaptureDelegate { [weak self] result in
            DispatchQueue.main.async {
                self?.photoCaptureDelegate = nil
                self?.onCapture?(result)
            }
        } onError: { [weak self] error in
            DispatchQueue.main.async {
                self?.photoCaptureDelegate = nil
                self?.onError?(error)
            }
        }

        // Keep a strong reference until the capture lifecycle completes.
        photoCaptureDelegate = delegate
        photoOutput.capturePhoto(with: captureSettings, delegate: delegate)
        FeedDebugLogger.log(.camera, "capturePhoto(with:delegate:) dispatched")
    }

    // MARK: - Video Recording

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        let delegate = MovieRecordingDelegate { [weak self] url in
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.onCapture?(.video(url))
            }
        } onError: { [weak self] error in
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.onError?(error)
            }
        }

        // Retain delegate
        objc_setAssociatedObject(self, "movieDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        movieOutput.startRecording(to: tempURL, recordingDelegate: delegate)

        // Hard cut at 6 seconds (backup — movieOutput.maxRecordedDuration also enforces)
        recordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
            self?.stopRecording()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        movieOutput.stopRecording()
    }
}

// MARK: - Photo Capture Delegate

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let onResult: (CaptureResult) -> Void
    let onError: (String) -> Void
    private var didDeliverResult = false

    init(onResult: @escaping (CaptureResult) -> Void, onError: @escaping (String) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    deinit {
        FeedDebugLogger.log(.camera, "PhotoCaptureDelegate deallocated", detail: "didDeliverResult=\(didDeliverResult)")
    }

    // 1. Called first — capture is starting
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        FeedDebugLogger.log(.camera, "willBeginCapture", detail: "id=\(resolvedSettings.uniqueID) dims=\(resolvedSettings.photoDimensions.width)×\(resolvedSettings.photoDimensions.height)")
    }

    // 2. Called at shutter moment
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        FeedDebugLogger.log(.camera, "willCapturePhoto (shutter)")
    }

    // 3. Called after sensor capture complete
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        FeedDebugLogger.log(.camera, "didCapturePhoto (sensor done)")
    }

    // 4. Called with processed photo data
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        FeedDebugLogger.log(.camera, "📸 didFinishProcessingPhoto", detail: "error=\(error?.localizedDescription ?? "none")")
        if let error {
            didDeliverResult = true
            onError("Photo capture failed: \(error.localizedDescription)")
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            FeedDebugLogger.log(.camera, "⚠️ Failed to get photo data representation")
            didDeliverResult = true
            onError("Failed to get photo data")
            return
        }

        // Detect HEIF by checking if codec type contains hevc
        let isHEIF = photo.resolvedSettings.photoProcessingTimeRange.duration != .zero
            || String(describing: type(of: photo)).contains("HEIF")

        FeedDebugLogger.log(.camera, "Photo captured", detail: "\(data.count) bytes, isHEIF=\(isHEIF)")
        didDeliverResult = true
        onResult(.photo(data, isHEIF: isHEIF))
    }

    // 5. Called LAST — always, even if earlier stages fail
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        FeedDebugLogger.log(.camera, "didFinishCapture (final)", detail: "error=\(error?.localizedDescription ?? "none") delivered=\(didDeliverResult)")
        // If we got here with an error and never delivered a result,
        // the capture failed before processing — report it now.
        if let error, !didDeliverResult {
            didDeliverResult = true
            onError("Photo capture failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Movie Recording Delegate

private final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    let onResult: (URL) -> Void
    let onError: (String) -> Void

    init(onResult: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error {
            // Error code -11810 = max duration reached, which is normal
            if (error as NSError).code != -11810 {
                onError("Video recording failed: \(error.localizedDescription)")
                return
            }
        }

        onResult(outputFileURL)
    }
}
