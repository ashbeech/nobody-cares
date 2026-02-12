//
//  ContentItem.swift
//  Nobody Cares
//
//  Content model — represents a piece of geo-locked content.
//  `mediaPath` is a Storage object key — NOT a signed URL.
//  The client generates short-lived signed URLs at display time.
//

import Foundation

enum ContentType: String, Codable {
    case image
    case video
}

struct ContentItem: Identifiable, Codable {
    let id: UUID
    let userId: UUID
    let username: String
    let contentType: ContentType
    let durationMs: Int?
    let mediaPath: String        // Storage object key (e.g. "originals/2026/02/11/uuid.heif")
    let distanceMeters: Double
    let captureLat: Double?      // Latitude where content was captured (for dev radar)
    let captureLng: Double?      // Longitude where content was captured (for dev radar)
    let createdAt: Date

    /// Signed URL generated client-side from mediaPath — not persisted
    var signedURL: URL?

    enum CodingKeys: String, CodingKey {
        case id = "content_id"
        case userId = "user_id"
        case username
        case contentType = "content_type"
        case durationMs = "duration_ms"
        case mediaPath = "media_path"
        case distanceMeters = "distance_meters"
        case captureLat = "capture_lat"
        case captureLng = "capture_lng"
        case createdAt = "created_at"
    }
}
