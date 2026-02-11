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
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - Processed Media

struct ProcessedMedia {
    let data: Data
    let contentType: ContentType
    let fileExtension: String
    let mimeType: String
    let durationMs: Int?

    var fileSizeBytes: Int { data.count }
}

// MARK: - Media Processor

enum MediaProcessor {
    private static let maxDimension: CGFloat = 1920
    private static let compressionQuality: CGFloat = 0.8
    private static let maxFileSize: Int = 50 * 1024 * 1024 // 50MB
    private static let maxVideoDuration: Double = 6.0

    // MARK: - Photo Processing

    /// Process a captured photo: resize, compress, strip EXIF.
    static func processPhoto(data: Data) throws -> ProcessedMedia {
        guard let sourceImage = UIImage(data: data) else {
            throw CaptureError.processingFailed
        }

        // Resize to max dimension
        let resized = resizeImage(sourceImage, maxDimension: maxDimension)

        // Try HEIF first, fall back to JPEG
        let (processedData, fileExtension, mimeType) = compressImage(resized)

        // Validate size
        guard processedData.count <= maxFileSize else {
            throw CaptureError.fileTooLarge
        }

        return ProcessedMedia(
            data: processedData,
            contentType: .image,
            fileExtension: fileExtension,
            mimeType: mimeType,
            durationMs: nil
        )
    }

    // MARK: - Video Processing

    /// Process a captured video: validate duration, export at 1080p.
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
            durationMs: durationMs
        )
    }

    // MARK: - Image Helpers

    private static func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longestEdge = max(size.width, size.height)

        guard longestEdge > maxDimension else { return image }

        let scale = maxDimension / longestEdge
        let newSize = CGSize(
            width: floor(size.width * scale),
            height: floor(size.height * scale)
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func compressImage(_ image: UIImage) -> (Data, String, String) {
        // Try HEIF first
        if let heifData = heifData(from: image, quality: compressionQuality) {
            return (heifData, "heic", "image/heic")
        }

        // Fall back to JPEG
        if let jpegData = image.jpegData(compressionQuality: compressionQuality) {
            return (jpegData, "jpg", "image/jpeg")
        }

        // Last resort — PNG
        let pngData = image.pngData() ?? Data()
        return (pngData, "png", "image/png")
    }

    private static func heifData(from image: UIImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // Strip EXIF by not copying metadata
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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
