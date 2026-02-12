//
//  FeedDataService.swift
//  Nobody Cares
//
//  Fetches nearby content via get_nearby_content() RPC,
//  generates short-lived signed URLs for media,
//  and manages Realtime subscriptions for new nearby content.
//

import Foundation
import Supabase
import Realtime

// MARK: - Feed Data Service

@Observable
final class FeedDataService {

    var items: [ContentItem] = []
    var isLoading = false
    var error: String?

    private var realtimeChannel: RealtimeChannelV2?
    private var currentCellId: String?
    private let pageSize = 20

    // MARK: - Fetch Nearby Content

    /// Fetch content near the given coordinates via Postgres RPC.
    func fetchNearbyContent(
        latitude: Double,
        longitude: Double,
        radius: Double = 30.0,
        offset: Int = 0
    ) async throws -> [ContentItem] {
        FeedDebugLogger.log(.data, "fetchNearbyContent — lat=\(latitude) lng=\(longitude) r=\(radius)m offset=\(offset)")
        isLoading = true
        defer { isLoading = false }

        let userId = try? await supabase.auth.session.user.id

        let params = NearbyContentParams(
            viewerLat: latitude,
            viewerLng: longitude,
            radiusMeters: radius,
            viewerUserId: userId?.uuidString,
            pageSize: pageSize,
            pageOffset: offset
        )

        var fetchedItems: [ContentItem] = try await supabase
            .rpc("get_nearby_content", params: params)
            .execute()
            .value

        FeedDebugLogger.log(.data, "fetchNearbyContent — RPC returned \(fetchedItems.count) items")

        // Generate signed URLs for each item
        fetchedItems = await generateSignedURLs(for: fetchedItems)
        FeedDebugLogger.log(.data, "fetchNearbyContent — signed URLs generated for \(fetchedItems.count) items")

        return fetchedItems
    }

    /// Refresh the feed from scratch
    func refresh(latitude: Double, longitude: Double, radius: Double = 30.0) async {
        FeedDebugLogger.log(.data, "refresh — START")
        do {
            let newItems = try await fetchNearbyContent(
                latitude: latitude,
                longitude: longitude,
                radius: radius
            )
            items = newItems
            error = nil
            FeedDebugLogger.log(.data, "refresh — SUCCESS, \(newItems.count) items")
        } catch {
            self.error = "Failed to load nearby content"
            FeedDebugLogger.log(.data, "refresh — FAILED: \(error)")
        }
    }

    /// Load the next page of content
    func loadMore(latitude: Double, longitude: Double, radius: Double = 30.0) async {
        FeedDebugLogger.log(.data, "loadMore — offset=\(items.count)")
        do {
            let moreItems = try await fetchNearbyContent(
                latitude: latitude,
                longitude: longitude,
                radius: radius,
                offset: items.count
            )
            FeedDebugLogger.log(.data, "loadMore — got \(moreItems.count) more items (total: \(items.count + moreItems.count))")
            items.append(contentsOf: moreItems)
        } catch {
            FeedDebugLogger.log(.data, "loadMore — FAILED: \(error)")
            // Silent failure for pagination
        }
    }

    // MARK: - Signed URL Generation

    /// Generate short-lived (1 hour) signed URLs for content items.
    private func generateSignedURLs(for items: [ContentItem]) async -> [ContentItem] {
        var updatedItems = items

        // Batch generate signed URLs
        let paths = items.map(\.mediaPath)

        do {
            let signedURLs = try await supabase.storage
                .from("content")
                .createSignedURLs(paths: paths, expiresIn: 3600) // 1 hour

            for (index, signedURL) in signedURLs.enumerated() where index < updatedItems.count {
                updatedItems[index].signedURL = signedURL
            }
        } catch {
            // If batch fails, try individual URLs as fallback
            for index in updatedItems.indices {
                do {
                    let url = try await supabase.storage
                        .from("content")
                        .createSignedURL(path: updatedItems[index].mediaPath, expiresIn: 3600)
                    updatedItems[index].signedURL = url
                } catch {
                    // Skip items where URL generation fails
                }
            }
        }

        return updatedItems
    }

    // MARK: - Realtime Subscription

    /// Subscribe to new content in the given S2 cell (for stationary mode).
    /// When the user isn't moving, we listen for server-pushed updates instead of polling.
    ///
    /// Listens for both INSERT and UPDATE events:
    ///   - INSERT: catches content created directly as visible (unlikely in normal flow,
    ///     since upload-confirm activates content via UPDATE, but safe to handle).
    ///   - UPDATE: catches content activation (is_deleted: true → false) from the
    ///     upload-confirm Edge Function. This is the primary path for new content
    ///     becoming visible in the feed.
    ///
    /// Requires: REPLICA IDENTITY FULL on the content table (see migration_v5).
    func subscribeToCell(cellId: String) async {
        FeedDebugLogger.log(.data, "subscribeToCell — \(cellId)")
        // Unsubscribe from previous cell
        await unsubscribeFromCell()

        currentCellId = cellId

        let channel = supabase.realtimeV2.channel("content-\(cellId)")

        let insertions = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "content",
            filter: .eq("cell_id", value: cellId)
        )

        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "content",
            filter: .eq("cell_id", value: cellId)
        )

        try? await channel.subscribeWithError()

        // Handle INSERT events
        Task {
            for await insertion in insertions {
                await handleRealtimeChange(record: insertion.record, event: "INSERT")
            }
        }

        // Handle UPDATE events (content activation)
        Task {
            for await update in updates {
                await handleRealtimeChange(record: update.record, event: "UPDATE")
            }
        }

        realtimeChannel = channel
    }

    /// Unsubscribe from Realtime updates
    func unsubscribeFromCell() async {
        if let channel = realtimeChannel {
            await channel.unsubscribe()
            realtimeChannel = nil
        }
        currentCellId = nil
    }

    /// Unified handler for Realtime INSERT and UPDATE events on the content table.
    ///
    /// Only posts a refresh notification if the content is now visible (is_deleted = false).
    /// This filters out:
    ///   - INSERT events for newly created (not yet confirmed) content (is_deleted = true)
    ///   - UPDATE events for soft-deletions or other non-activation updates
    ///
    /// The Realtime payload contains the raw row data but not the joined
    /// query result (username, distance, signed URL). Rather than trying
    /// to reconstruct a partial ContentItem, we signal the feed to refresh
    /// so it can re-fetch via the full get_nearby_content RPC.
    private func handleRealtimeChange(record: [String: AnyJSON], event: String) async {
        // Only trigger refresh if the content is visible (is_deleted = false).
        guard record["is_deleted"]?.boolValue == false else {
            FeedDebugLogger.log(.data, "⚡ Realtime \(event) detected — SKIPPED (content not visible)")
            return
        }

        guard record["id"] != nil else { return }

        FeedDebugLogger.log(.data, "⚡ Realtime \(event) detected — posting newNearbyContentAvailable")
        await MainActor.run {
            NotificationCenter.default.post(name: .newNearbyContentAvailable, object: nil)
        }
    }
}

// MARK: - RPC Parameter Types

private struct NearbyContentParams: Encodable {
    let viewerLat: Double
    let viewerLng: Double
    let radiusMeters: Double
    let viewerUserId: String?
    let pageSize: Int
    let pageOffset: Int

    enum CodingKeys: String, CodingKey {
        case viewerLat = "viewer_lat"
        case viewerLng = "viewer_lng"
        case radiusMeters = "radius_meters"
        case viewerUserId = "viewer_user_id"
        case pageSize = "page_size"
        case pageOffset = "page_offset"
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newNearbyContentAvailable = Notification.Name("newNearbyContentAvailable")
}
