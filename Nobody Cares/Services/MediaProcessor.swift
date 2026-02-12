//
//  MediaProcessor.swift
//  Nobody Cares
//
//  Client-side media processing before upload.
//
//  Per spec Section 7.3 and 15.2:
//  - Images: resize to max 1920px longest edge, HEIF 0.8 quality, strip EXIF
//  - Video: H.264 MOV, 1080p/30fps, max 6s, AAC audio
//  - Validate file size < 50MB
//

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Processed Media

struct ProcessedMedia {
    let data: Data
    let contentType: ContentType
    let fileExtension: String
    let mimeType: String
    let durationMs: Int?
    /// JPEG thumbnail extracted from the local video file (nil for images)
    let thumbnailData: Data?

    var fileSizeBytes: Int { data.count }
}

// MARK: - Media Processor

enum MediaProcessor {
    private static let maxDimension: CGFloat = 1920
    private static let compressionQuality: CGFloat = 0.8
    private static let maxFileSize: Int = 50 * 1024 * 1024 // 50MB
    private static let maxVideoDuration: Double = 6.0

    // MARK: - Photo Processing

    /// Process a captured photo: downsample, compress, strip EXIF.
    ///
    /// Uses ImageIO to decode directly at the target resolution, avoiding
    /// the full-size bitmap allocation that `UIImage(data:)` + redraw requires.
    /// Safe to call from any thread (no UIKit dependency).
    static func processPhoto(data: Data) throws -> ProcessedMedia {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif

        guard let cgImage = downsampledCGImage(from: data, maxPixelSize: Int(maxDimension)) else {
            throw CaptureError.processingFailed
        }

        #if DEBUG
        let t1 = CFAbsoluteTimeGetCurrent()
        print("[MediaProcessor] Downsample: \(String(format: "%.3f", t1 - t0))s → \(cgImage.width)×\(cgImage.height)")
        #endif

        // Encode: HEIC preferred, JPEG fallback
        let (processedData, fileExtension, mimeType) = try encodeCGImage(cgImage)

        #if DEBUG
        let t2 = CFAbsoluteTimeGetCurrent()
        print("[MediaProcessor] Encode (\(fileExtension)): \(String(format: "%.3f", t2 - t1))s → \(processedData.count) bytes")
        #endif

        // Validate size
        guard processedData.count <= maxFileSize else {
            throw CaptureError.fileTooLarge
        }

        return ProcessedMedia(
            data: processedData,
            contentType: .image,
            fileExtension: fileExtension,
            mimeType: mimeType,
            durationMs: nil,
            thumbnailData: nil
        )
    }

    // MARK: - Video Processing

    /// Process a captured video: validate duration, export at 1080p, generate thumbnail.
    static func processVideo(url: URL) async throws -> ProcessedMedia {
        let asset = AVURLAsset(url: url)

        // Get duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let durationMs = Int(min(durationSeconds, maxVideoDuration) * 1000)

        // Export with compression
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        try await exportVideo(asset: asset, to: outputURL, maxDuration: maxVideoDuration)

        // Generate thumbnail from the local exported file before cleanup.
        // Use t = min(0.5s, duration * 0.05) to avoid black first frames.
        let thumbnailData = await generateThumbnail(from: outputURL, duration: durationSeconds)

        let data = try Data(contentsOf: outputURL)

        // Clean up temp file
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: url)

        guard data.count <= maxFileSize else {
            throw CaptureError.fileTooLarge
        }

        return ProcessedMedia(
            data: data,
            contentType: .video,
            fileExtension: "mov",
            mimeType: "video/quicktime",
            durationMs: durationMs,
            thumbnailData: thumbnailData
        )
    }

    // MARK: - ImageIO Helpers

    /// Decode + downsample in a single pass via ImageIO.
    /// This avoids allocating the full-resolution bitmap that `UIImage(data:)` requires.
    /// On a 48 MP capture the difference is ~180 MB vs ~12 MB of pixel data.
    private static func downsampledCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary)
    }

    /// Encode a CGImage to HEIC (preferred) or JPEG (fallback).
    private static func encodeCGImage(_ cgImage: CGImage) throws -> (Data, String, String) {
        // Photos are always opaque. CGImageSource may produce a thumbnail with an
        // alpha channel (AlphaPremulLast) inherited from the source container.
        // Stripping it prevents CGImageDestination warnings and halves decode memory.
        let opaqueImage = opaqueVariant(of: cgImage)

        // Try HEIC first
        if let heicData = encodeToFormat(opaqueImage, type: UTType.heic.identifier as CFString, quality: compressionQuality) {
            return (heicData, "heic", "image/heic")
        }

        // Fall back to JPEG
        if let jpegData = encodeToFormat(opaqueImage, type: UTType.jpeg.identifier as CFString, quality: compressionQuality) {
            return (jpegData, "jpg", "image/jpeg")
        }

        throw CaptureError.processingFailed
    }

    /// Return a copy of `image` with the alpha channel stripped (noneSkipLast).
    /// If the image is already opaque, returns it unchanged.
    private static func opaqueVariant(of image: CGImage) -> CGImage {
        let alpha = image.alphaInfo
        if alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast {
            return image
        }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Encode a CGImage to the given UTType using CGImageDestination.
    /// EXIF is stripped by virtue of not copying source metadata.
    private static func encodeToFormat(_ cgImage: CGImage, type: CFString, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    // MARK: - Thumbnail Generation

    /// Extract a JPEG thumbnail from a local video file.
    /// Uses t = min(0.5s, duration * 0.05) to avoid black first frames.
    /// Resizes to 720px width max, JPEG quality 0.75.
    private static func generateThumbnail(from videoURL: URL, duration: Double) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)

        // Pick a frame slightly after the start to avoid black first frames
        let seekTime = min(0.5, duration * 0.05)
        let time = CMTime(seconds: seekTime, preferredTimescale: 600)

        guard let result = try? await generator.image(at: time) else {
            return nil
        }

        // Encode CGImage directly via ImageIO (no UIImage dependency)
        return encodeToFormat(result.image, type: UTType.jpeg.identifier as CFString, quality: 0.75)
    }

    // MARK: - Video Helpers

    private static func exportVideo(asset: AVAsset, to outputURL: URL, maxDuration: Double) async throws {
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1920x1080
        ) else {
            // Fall back to lower preset
            guard let fallbackSession = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                throw CaptureError.processingFailed
            }
            try await performExport(session: fallbackSession, to: outputURL, maxDuration: maxDuration)
            return
        }

        try await performExport(session: exportSession, to: outputURL, maxDuration: maxDuration)
    }

    private static func performExport(
        session: AVAssetExportSession,
        to outputURL: URL,
        maxDuration: Double
    ) async throws {
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true

        // Trim to max duration
        let duration = try await session.asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        if durationSeconds > maxDuration {
            let endTime = CMTime(seconds: maxDuration, preferredTimescale: 600)
            session.timeRange = CMTimeRange(start: .zero, end: endTime)
        }

        // Strip metadata
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()

        await session.export()

        guard session.status == .completed else {
            throw CaptureError.processingFailed
        }
    }
}
