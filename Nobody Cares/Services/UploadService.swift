//
//  UploadService.swift
//  Nobody Cares
//
//  Orchestrates the full content upload pipeline:
//  1. Request upload slot (Edge Function → content record + signed URL)
//  2. Upload binary to Supabase Storage via signed URL
//  3. Confirm upload (Edge Function → activate content record)
//
//  Every Edge Function call includes App Attest assertion headers so
//  the server can verify the request came from the original attested
//  device — a stolen JWT alone cannot perform uploads.
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
    /// - Parameter appAttest: The attestation service used to sign each
    ///   Edge Function call with a hardware-bound assertion.
    func upload(
        media: ProcessedMedia,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        appAttest: AppAttestService
    ) async throws {
        // 1. Request upload slot from Edge Function
        print("[UploadService] Step 1/3: Requesting upload slot...")
        let uploadSlot = try await requestUploadSlot(
            media: media,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            appAttest: appAttest
        )
        print("[UploadService] Step 1/3 complete: contentId=\(uploadSlot.contentId)")

        // 2. Upload file to Storage via signed URL
        print("[UploadService] Step 2/3: Uploading \(media.fileSizeBytes) bytes to Storage...")
        try await uploadToStorage(
            data: media.data,
            mimeType: media.mimeType,
            signedURL: uploadSlot.uploadURL,
            token: uploadSlot.uploadToken
        )
        print("[UploadService] Step 2/3 complete: file uploaded")

        // 3. Confirm upload
        print("[UploadService] Step 3/3: Confirming upload...")
        try await confirmUpload(
            contentId: uploadSlot.contentId,
            storagePath: uploadSlot.storagePath,
            appAttest: appAttest
        )
        print("[UploadService] Step 3/3 complete: upload confirmed")
    }

    // MARK: - Step 1: Request Upload Slot

    private func requestUploadSlot(
        media: ProcessedMedia,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        appAttest: AppAttestService
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

        let headers = try await assertionHeaders(for: requestBody, using: appAttest)
        print("[UploadService] Assertion headers: \(headers.isEmpty ? "empty (dev bypass)" : "present")")

        let response: UploadRequestResponse
        do {
            response = try await supabase.functions
                .invoke("upload-request", options: .init(headers: headers, body: requestBody))
        } catch {
            print("[UploadService] upload-request Edge Function error: \(error)")
            throw UploadError.requestFailed("Edge Function call failed: \(error.localizedDescription)")
        }

        guard let contentId = response.contentId,
              let uploadURL = response.uploadUrl,
              let storagePath = response.storagePath else {
            let errorDetail = "code=\(response.code ?? "nil"), error=\(response.error ?? "nil")"
            print("[UploadService] upload-request rejected: \(errorDetail)")
            if let code = response.code, code == "assertion_failed" {
                throw UploadError.attestationRequired
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

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            print("[UploadService] Storage upload failed: status=\(statusCode), body=\(body.prefix(500))")
            throw UploadError.uploadFailed("Storage upload failed with status \(statusCode)")
        }
    }

    // MARK: - Step 3: Confirm Upload

    private func confirmUpload(
        contentId: String,
        storagePath: String,
        appAttest: AppAttestService
    ) async throws {
        let body = UploadConfirmBody(
            contentId: contentId,
            storagePath: storagePath
        )

        let headers = try await assertionHeaders(for: body, using: appAttest)

        let response: UploadConfirmResponse
        do {
            response = try await supabase.functions
                .invoke("upload-confirm", options: .init(headers: headers, body: body))
        } catch {
            print("[UploadService] upload-confirm Edge Function error: \(error)")
            throw UploadError.confirmFailed("Edge Function call failed: \(error.localizedDescription)")
        }

        guard response.confirmed == true else {
            let errorDetail = "code=\(response.code ?? "nil"), error=\(response.error ?? "nil")"
            print("[UploadService] upload-confirm rejected: \(errorDetail)")
            if let code = response.code, code == "validation_failed" {
                throw UploadError.confirmFailed(response.error ?? "File validation failed")
            }
            throw UploadError.confirmFailed(response.error ?? "Confirmation failed")
        }
    }

    // MARK: - Assertion Headers

    /// Encode the request body, sign it with the device's attested key,
    /// and return the assertion + key ID as HTTP headers.
    ///
    /// In DEBUG builds on the simulator (where App Attest is unavailable),
    /// returns an empty dictionary so the dev-bypass on the server kicks in.
    private func assertionHeaders<T: Encodable>(
        for body: T,
        using appAttest: AppAttestService
    ) async throws -> [String: String] {
        let bodyData = try JSONEncoder().encode(body)

        guard let assertionB64 = await appAttest.assertionHeader(for: bodyData),
              let keyId = appAttest.keyId else {
            #if DEBUG
            return [:] // Simulator / unsupported — server dev-bypass handles this
            #else
            throw UploadError.attestationRequired
            #endif
        }

        return [
            "X-App-Assertion": assertionB64,
            "X-App-KeyId": keyId,
        ]
    }
}

// MARK: - Upload Errors

enum UploadError: Error, LocalizedError {
    case requestFailed(String)
    case invalidURL
    case uploadFailed(String)
    case confirmFailed(String)
    case rateLimited
    case attestationRequired

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return "Upload request failed: \(msg)"
        case .invalidURL: return "Invalid upload URL"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .confirmFailed(let msg): return "Upload confirmation failed: \(msg)"
        case .rateLimited: return "Rate limit exceeded"
        case .attestationRequired: return "Device attestation required. Reinstall the app."
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
    let code: String?

    enum CodingKeys: String, CodingKey {
        case confirmed
        case contentId = "content_id"
        case error
        case code
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
