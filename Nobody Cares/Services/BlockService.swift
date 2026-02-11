//
//  BlockService.swift
//  Nobody Cares
//
//  Manages blocking users — writes to the `blocks` table.
//  Block immediately hides all content from that user.
//

import Foundation

final class BlockService {
    static let shared = BlockService()
    private init() {}

    /// Block a user. Immediately hides all their content from the blocker.
    func blockUser(blockedUserId: UUID) async throws {
        let params = BlockParams(blockedId: blockedUserId.uuidString)

        try await supabase
            .from("blocks")
            .insert(params)
            .execute()

        AnalyticsService.shared.track(.userBlocked, metadata: [
            "blocked_user_id": blockedUserId.uuidString,
        ])
    }

    /// Unblock a user.
    func unblockUser(blockedUserId: UUID) async throws {
        guard let currentUserId = try? await supabase.auth.session.user.id else { return }

        try await supabase
            .from("blocks")
            .delete()
            .eq("blocker_id", value: currentUserId.uuidString)
            .eq("blocked_id", value: blockedUserId.uuidString)
            .execute()
    }

    /// Check if a user is blocked.
    func isBlocked(userId: UUID) async -> Bool {
        guard let currentUserId = try? await supabase.auth.session.user.id else { return false }

        struct BlockRow: Decodable {
            let blockerId: String
            enum CodingKeys: String, CodingKey {
                case blockerId = "blocker_id"
            }
        }

        do {
            let result: [BlockRow] = try await supabase
                .from("blocks")
                .select("blocker_id")
                .eq("blocker_id", value: currentUserId.uuidString)
                .eq("blocked_id", value: userId.uuidString)
                .execute()
                .value

            return !result.isEmpty
        } catch {
            return false
        }
    }
}

// MARK: - Block Params

private struct BlockParams: Encodable {
    let blockedId: String

    enum CodingKeys: String, CodingKey {
        case blockedId = "blocked_id"
    }
}
