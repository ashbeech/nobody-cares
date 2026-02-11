//
//  UploadService.swift
//  Nobody Cares
//
//  Orchestrates the full content upload pipeline:
//  1. Request upload slot (Edge Function → content record + signed URL)
//  2. Upload binary to Supabase Storage via signed URL
//  3. Confirm upload (Edge Function → activate content record)
//
//  Per spec Section 7.4 and 15.2
//

import Foundation

// MARK: - Upload Service

final class UploadService {
    static let shared = UploadService()
    private init() {}

    // MARK: - Upload

    /// Full upload pipeline: request → upload → confirm.
    func upload(
        media: ProcessedMedia,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double
    ) async throws {
        // 1. Request upload slot from Edge Function
        let uploadSlot = try await requestUploadSlot(
            media: media,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy
        )

        // 2. Upload file to Storage via signed URL
        try await uploadToStorage(
            data: media.data,
            mimeType: media.mimeType,
            signedURL: uploadSlot.uploadURL,
            token: uploadSlot.uploadToken
        )

        // 3. Confirm upload
        try await confirmUpload(
            contentId: uploadSlot.contentId,
            storagePath: uploadSlot.storagePath
        )
    }

    // MARK: - Step 1: Request Upload Slot

    private func requestUploadSlot(
        media: ProcessedMedia,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double
    ) async throws -> UploadSlot {
        let cellId = S2CellCalculator.cellId(latitude: latitude, longitude: longitude)

        let requestBody = UploadRequestBody(
            contentType: media.contentType.rawValue,
            fileExtension: media.fileExtension,
            fileSizeBytes: media.fileSizeBytes,
            captureLat: latitude,
            captureLng: longitude,
            horizontalAccuracy: horizontalAccuracy,
            durationMs: media.durationMs,
            cellId: cellId
        )

        let response: UploadRequestResponse = try await supabase.functions
            .invoke("upload-request", options: .init(body: requestBody))

        guard let contentId = response.contentId,
              let uploadURL = response.uploadUrl,
              let storagePath = response.storagePath else {
            if let code = response.code, code == "captcha_required" {
                throw UploadError.captchaRequired
            }
            if let code = response.code, code == "rate_limited" {
                throw UploadError.rateLimited
            }
            throw UploadError.requestFailed(response.error ?? "Unknown error")
        }

        return UploadSlot(
            contentId: contentId,
            uploadURL: uploadURL,
            uploadToken: response.uploadToken ?? "",
            storagePath: storagePath
        )
    }

    // MARK: - Step 2: Upload to Storage

    private func uploadToStorage(
        data: Data,
        mimeType: String,
        signedURL: String,
        token: String
    ) async throws {
        guard let url = URL(string: signedURL) else {
            throw UploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UploadError.uploadFailed("Storage upload failed with status \(statusCode)")
        }
    }

    // MARK: - Step 3: Confirm Upload

    private func confirmUpload(contentId: String, storagePath: String) async throws {
        let body = UploadConfirmBody(
            contentId: contentId,
            storagePath: storagePath
        )

        let response: UploadConfirmResponse = try await supabase.functions
            .invoke("upload-confirm", options: .init(body: body))

        guard response.confirmed == true else {
            throw UploadError.confirmFailed(response.error ?? "Confirmation failed")
        }
    }
}

// MARK: - Upload Errors

enum UploadError: Error, LocalizedError {
    case requestFailed(String)
    case invalidURL
    case uploadFailed(String)
    case confirmFailed(String)
    case captchaRequired
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return "Upload request failed: \(msg)"
        case .invalidURL: return "Invalid upload URL"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .confirmFailed(let msg): return "Upload confirmation failed: \(msg)"
        case .captchaRequired: return "Human verification required"
        case .rateLimited: return "Rate limit exceeded"
        }
    }
}

// MARK: - Request / Response Types

private struct UploadRequestBody: Encodable {
    let contentType: String
    let fileExtension: String
    let fileSizeBytes: Int
    let captureLat: Double
    let captureLng: Double
    let horizontalAccuracy: Double
    let durationMs: Int?
    let cellId: String

    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case fileExtension = "file_extension"
        case fileSizeBytes = "file_size_bytes"
        case captureLat = "capture_lat"
        case captureLng = "capture_lng"
        case horizontalAccuracy = "horizontal_accuracy"
        case durationMs = "duration_ms"
        case cellId = "cell_id"
    }
}

private struct UploadRequestResponse: Decodable {
    let contentId: String?
    let uploadUrl: String?
    let uploadToken: String?
    let storagePath: String?
    let error: String?
    let code: String?

    enum CodingKeys: String, CodingKey {
        case contentId = "content_id"
        case uploadUrl = "upload_url"
        case uploadToken = "upload_token"
        case storagePath = "storage_path"
        case error
        case code
    }
}

private struct UploadConfirmBody: Encodable {
    let contentId: String
    let storagePath: String

    enum CodingKeys: String, CodingKey {
        case contentId = "content_id"
        case storagePath = "storage_path"
    }
}

private struct UploadConfirmResponse: Decodable {
    let confirmed: Bool?
    let contentId: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case confirmed
        case contentId = "content_id"
        case error
    }
}

// MARK: - Upload Slot

private struct UploadSlot {
    let contentId: String
    let uploadURL: String
    let uploadToken: String
    let storagePath: String
}

// MARK: - S2 Cell ID Calculator

/// Simplified S2 cell ID computation.
/// Uses lat/lng to generate a deterministic cell identifier
/// at approximately level 21 (~5m resolution) for pre-filtering.
enum S2CellCalculator {
    static func cellId(latitude: Double, longitude: Double, level: Int = 21) -> String {
        // Quantize lat/lng to grid cells at ~5m resolution
        // At level 21, each cell is approximately 5m × 5m
        let latSteps = pow(2.0, Double(level))
        let lngSteps = pow(2.0, Double(level))

        let normalizedLat = (latitude + 90.0) / 180.0
        let normalizedLng = (longitude + 180.0) / 360.0

        let latCell = Int(normalizedLat * latSteps)
        let lngCell = Int(normalizedLng * lngSteps)

        return "\(latCell)_\(lngCell)_\(level)"
    }
}
