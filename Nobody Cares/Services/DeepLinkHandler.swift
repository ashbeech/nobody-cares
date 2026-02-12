//
//  DeepLinkHandler.swift
//  Nobody Cares
//
//  Handles universal links: nobodycares.app/c/{content_id}
//
//  Per spec Section 13:
//  - Within capture radius → show content
//  - Outside capture radius → "ACCESS DENIED" dialog
//

import CoreLocation
import Foundation

// MARK: - Deep Link Result

enum DeepLinkResult {
    case content(ContentItem)
    case accessDenied(distance: Double)
    case notFound
    case error(String)
}

// MARK: - Deep Link Handler

final class DeepLinkHandler {
    static let shared = DeepLinkHandler()
    private init() {}

    /// Parse a deep link URL and return the content ID if valid.
    func parseContentId(from url: URL) -> UUID? {
        // Expected format: https://nobodycares.app/c/{content_id}
        let pathComponents = url.pathComponents
        guard pathComponents.count >= 3,
              pathComponents[1] == "c",
              let id = UUID(uuidString: pathComponents[2]) else {
            return nil
        }
        return id
    }

    /// Resolve a deep link: fetch content, check proximity, return result.
    func resolve(contentId: UUID, currentLocation: CLLocation?) async -> DeepLinkResult {
        AnalyticsService.shared.track(.deepLinkOpened, metadata: [
            "content_id": contentId.uuidString,
        ])

        // Fetch content details
        do {
            struct ContentRow: Decodable {
                let id: UUID
                let userId: UUID
                let captureLat: Double
                let captureLng: Double
                let contentType: String
                let durationMs: Int?
                let originalPath: String
                let compressedPath: String?
                let isDeleted: Bool

                enum CodingKeys: String, CodingKey {
                    case id
                    case userId = "user_id"
                    case captureLat = "capture_lat"
                    case captureLng = "capture_lng"
                    case contentType = "content_type"
                    case durationMs = "duration_ms"
                    case originalPath = "original_path"
                    case compressedPath = "compressed_path"
                    case isDeleted = "is_deleted"
                }
            }

            let row: ContentRow = try await supabase
                .from("content")
                .select("id, user_id, capture_lat, capture_lng, content_type, duration_ms, original_path, compressed_path, is_deleted")
                .eq("id", value: contentId.uuidString)
                .single()
                .execute()
                .value

            if row.isDeleted {
                return .notFound
            }

            // Check proximity
            guard let location = currentLocation else {
                return .error("LOCATION UNAVAILABLE. Cannot verify proximity to content.")
            }

            let contentLocation = CLLocation(latitude: row.captureLat, longitude: row.captureLng)
            let distance = location.distance(from: contentLocation)

            if distance > 14.0 { // Use exit radius for deep links
                AnalyticsService.shared.track(.deepLinkDenied, metadata: [
                    "content_id": contentId.uuidString,
                    "distance": String(Int(distance)),
                ])
                return .accessDenied(distance: distance)
            }

            // Build content item
            let mediaPath = row.compressedPath ?? row.originalPath

            // Fetch username
            struct UserRow: Decodable { let username: String }
            let user: UserRow = try await supabase
                .from("users")
                .select("username")
                .eq("id", value: row.userId.uuidString)
                .single()
                .execute()
                .value

            // Generate signed URL
            let signedURL = try await supabase.storage
                .from("content")
                .createSignedURL(path: mediaPath, expiresIn: 3600)

            var item = ContentItem(
                id: row.id,
                userId: row.userId,
                username: user.username,
                contentType: ContentType(rawValue: row.contentType) ?? .image,
                durationMs: row.durationMs,
                mediaPath: mediaPath,
                thumbnailPath: nil,
                distanceMeters: distance,
                captureLat: nil,
                captureLng: nil,
                createdAt: .now
            )
            item.signedURL = signedURL

            return .content(item)

        } catch {
            return .notFound
        }
    }
}
