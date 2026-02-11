//
//  APIGuard.swift
//  Nobody Cares
//
//  Wraps sensitive API calls with rate limit checking, trust score
//  enforcement, and ban detection. This is the client-side enforcement layer.
//
//  Server-side enforcement (attestation, IP rate limits) is authoritative.
//  This guard provides early rejection on the client to avoid wasted
//  round-trips and gives the user meaningful feedback.
//
//  Flow:
//  1. Before an API call, check_rate_limit() is called via RPC
//  2. If "ok" → proceed
//  3. If "soft_exceeded" → proceed (server will enforce if needed)
//  4. If "hard_exceeded" → decrease trust score, reject
//  5. Ban check happens at initialization and is enforced globally
//

import Foundation
import Supabase

// MARK: - Rate Limit Action Types

enum RateLimitAction: String {
    case contentCreate = "content_create"
    case videoCreate = "video_create"
    case uploadRequest = "upload_request"
    case feedQuery = "feed_query"
    case reportSubmit = "report_submit"
    case locationUpdate = "location_update"
    case deviceRegistration = "device_registration"
}

// MARK: - Rate Limit Result

enum RateLimitResult: String {
    case ok
    case softExceeded = "soft_exceeded"
    case hardExceeded = "hard_exceeded"
}

// MARK: - Guard Errors

enum APIGuardError: Error, LocalizedError {
    case banned
    case rateLimitExceeded

    var errorDescription: String? {
        switch self {
        case .banned:
            return "YOUR ACCESS HAS BEEN REVOKED. This decision is final. Nobody cares."
        case .rateLimitExceeded:
            return "RATE LIMIT EXCEEDED. Slow down. The void does not appreciate urgency."
        }
    }
}

// MARK: - API Guard Service

@Observable
final class APIGuard {
    var isBanned = false

    // MARK: - Ban Check

    /// Check if the current user is banned. Called at app launch.
    func checkBanStatus() async {
        do {
            let result: Bool = try await supabase
                .rpc("check_banned")
                .execute()
                .value

            await MainActor.run {
                isBanned = result
            }
        } catch {
            // If we can't check, don't block — the RLS policies will enforce anyway
        }
    }

    // MARK: - Rate Limit Check

    /// Check rate limit for an action. Returns the result.
    /// Call this before performing the actual API operation.
    func checkRateLimit(action: RateLimitAction) async throws -> RateLimitResult {
        guard !isBanned else { throw APIGuardError.banned }

        guard let userId = try? await supabase.auth.session.user.id else {
            return .ok // Not authenticated yet, skip check
        }

        let params = CheckRateLimitParams(pUserId: userId.uuidString, pAction: action.rawValue)

        let result: String = try await supabase
            .rpc("check_rate_limit", params: params)
            .execute()
            .value

        return RateLimitResult(rawValue: result) ?? .ok
    }

    // MARK: - Guarded Operation

    /// Execute an operation with rate limit protection.
    /// - Parameters:
    ///   - action: The rate limit action type
    ///   - operation: The actual operation to perform
    /// - Returns: The operation result
    func guardedOperation<T>(
        action: RateLimitAction,
        operation: () async throws -> T
    ) async throws -> T {
        guard !isBanned else { throw APIGuardError.banned }

        let rateLimitResult = try await checkRateLimit(action: action)

        switch rateLimitResult {
        case .ok:
            return try await operation()

        case .softExceeded:
            // Soft limit: proceed but the server may enforce stricter checks.
            // App Attest assertions are the real gate — not CAPTCHA.
            return try await operation()

        case .hardExceeded:
            // Hard limit: decrease trust score and reject
            try await decreaseTrustScore(amount: 5, reason: "rate_limit_hard_exceeded")
            throw APIGuardError.rateLimitExceeded
        }
    }

    // MARK: - Trust Score Decrease

    private func decreaseTrustScore(amount: Int, reason: String) async throws {
        guard let userId = try? await supabase.auth.session.user.id else { return }

        let params = DecreaseTrustParams(
            pUserId: userId.uuidString,
            pAmount: amount,
            pReason: reason
        )

        let newScore: Int = try await supabase
            .rpc("decrease_trust_score", params: params)
            .execute()
            .value

        if newScore == 0 {
            await MainActor.run {
                isBanned = true
            }
        }
    }
}

// MARK: - RPC Parameter Types

private struct CheckRateLimitParams: Encodable {
    let pUserId: String
    let pAction: String

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
        case pAction = "p_action"
    }
}

private struct DecreaseTrustParams: Encodable {
    let pUserId: String
    let pAmount: Int
    let pReason: String

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
        case pAmount = "p_amount"
        case pReason = "p_reason"
    }
}
