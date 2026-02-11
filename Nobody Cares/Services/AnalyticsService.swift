//
//  AnalyticsService.swift
//  Nobody Cares
//
//  Instruments all analytics events per spec Section 17.1.
//  Writes to the `analytics_events` table in Supabase.
//

import Foundation

// MARK: - Event Types

enum AnalyticsEvent: String {
    // Content lifecycle
    case contentCreated = "content_created"
    case contentViewed = "content_viewed"
    case contentReported = "content_reported"

    // User actions
    case userBlocked = "user_blocked"
    case contentShared = "content_shared"
    case identityReassigned = "identity_reassigned"
    case accountDeleted = "account_deleted"

    // Navigation
    case feedOpened = "feed_opened"
    case cameraOpened = "camera_opened"
    case settingsOpened = "settings_opened"

    // Errors
    case uploadFailed = "upload_failed"
    case locationUnavailable = "location_unavailable"
    case networkError = "network_error"
    case gpsInaccurate = "gps_inaccurate"

    // Security
    case captchaShown = "captcha_shown"
    case captchaSolved = "captcha_solved"
    case rateLimitHit = "rate_limit_hit"

    // Deep links
    case deepLinkOpened = "deep_link_opened"
    case deepLinkDenied = "deep_link_denied"
}

// MARK: - Analytics Service

final class AnalyticsService: @unchecked Sendable {
    static let shared = AnalyticsService()
    private init() {}

    /// Track an event with optional metadata.
    func track(_ event: AnalyticsEvent, metadata: [String: String] = [:]) {
        Task {
            await send(event: event, metadata: metadata)
        }
    }

    /// Track an event asynchronously (for when you need to await).
    func trackAsync(_ event: AnalyticsEvent, metadata: [String: String] = [:]) async {
        await send(event: event, metadata: metadata)
    }

    // MARK: - Send to Supabase

    private func send(event: AnalyticsEvent, metadata: [String: String]) async {
        let userId = try? await supabase.auth.session.user.id

        let params = AnalyticsParams(
            eventType: event.rawValue,
            userId: userId?.uuidString,
            metadata: metadata
        )

        do {
            try await supabase
                .from("analytics_events")
                .insert(params)
                .execute()
        } catch {
            #if DEBUG
            print("[Analytics] Failed to track \(event.rawValue): \(error.localizedDescription)")
            #endif
        }
    }
}

// MARK: - Params

private struct AnalyticsParams: Encodable {
    let eventType: String
    let userId: String?
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case userId = "user_id"
        case metadata
    }
}
