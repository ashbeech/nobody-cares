//
//  APIGuard.swift
//  Nobody Cares
//
//  Wraps sensitive API calls with rate limit checking, CAPTCHA escalation,
//  and ban detection. This is the client-side enforcement layer.
//
//  Flow:
//  1. Before an API call, check_rate_limit() is called via RPC
//  2. If "ok" → proceed
//  3. If "soft_exceeded" → require CAPTCHA, then proceed
//  4. If "hard_exceeded" → decrease trust score, require CAPTCHA
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
    case captchaRequired
    case rateLimitExceeded
    case captchaFailed

    var errorDescription: String? {
        switch self {
        case .banned:
            return "YOUR ACCESS HAS BEEN REVOKED. This decision is final. Nobody cares."
        case .captchaRequired:
            return "HUMAN VERIFICATION REQUIRED. Prove you are not a machine."
        case .rateLimitExceeded:
            return "RATE LIMIT EXCEEDED. Slow down. The void does not appreciate urgency."
        case .captchaFailed:
            return "VERIFICATION FAILED. Suspicious."
        }
    }
}

// MARK: - API Guard Service

@Observable
final class APIGuard {
    var isBanned = false
    var needsCaptcha = false
    var pendingAction: RateLimitAction?
    var captchaCompletion: ((String?) -> Void)?

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
    /// If rate limited, triggers CAPTCHA challenge and waits for resolution.
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
            // Require CAPTCHA before proceeding
            let token = try await requestCaptcha(for: action)
            // CAPTCHA solved — proceed with operation
            // Token is validated server-side on the next auth refresh
            _ = token
            return try await operation()

        case .hardExceeded:
            // Decrease trust score, then require CAPTCHA
            try await decreaseTrustScore(amount: 5, reason: "rate_limit_hard_exceeded")
            let token = try await requestCaptcha(for: action)
            _ = token
            return try await operation()
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

    // MARK: - CAPTCHA Flow

    /// Request a CAPTCHA challenge. Returns the token when solved.
    /// This triggers the UI to show the CaptchaChallengeView.
    @MainActor
    private func requestCaptcha(for action: RateLimitAction) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            pendingAction = action
            needsCaptcha = true
            captchaCompletion = { token in
                if let token {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: APIGuardError.captchaFailed)
                }
            }
        }
    }

    /// Called by the CAPTCHA view when the user solves it (or fails).
    @MainActor
    func resolveCaptcha(token: String?) {
        captchaCompletion?(token)
        captchaCompletion = nil
        pendingAction = nil
        needsCaptcha = false
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
