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
        radius: Double = 10.0,
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
    func refresh(latitude: Double, longitude: Double, radius: Double = 10.0) async {
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
    func loadMore(latitude: Double, longitude: Double, radius: Double = 10.0) async {
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

    /// Generate short-lived (1 hour) signed URLs for content items (media + thumbnails).
    private func generateSignedURLs(for items: [ContentItem]) async -> [ContentItem] {
        var updatedItems = items

        // --- Media signed URLs ---
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

        // --- Thumbnail signed URLs ---
        let thumbnailPaths = updatedItems.compactMap { $0.thumbnailPath }
        if !thumbnailPaths.isEmpty {
            do {
                let thumbnailURLs = try await supabase.storage
                    .from("thumbnails")
                    .createSignedURLs(paths: thumbnailPaths, expiresIn: 3600)

                // Map signed URLs back by matching paths
                var urlByPath: [String: URL] = [:]
                for (i, path) in thumbnailPaths.enumerated() where i < thumbnailURLs.count {
                    urlByPath[path] = thumbnailURLs[i]
                }
                for index in updatedItems.indices {
                    if let thumbPath = updatedItems[index].thumbnailPath,
                       let url = urlByPath[thumbPath] {
                        updatedItems[index].thumbnailURL = url
                    }
                }
                FeedDebugLogger.log(.data, "thumbnail signed URLs generated for \(thumbnailPaths.count) items")
            } catch {
                // Non-fatal: feed works without thumbnails
                FeedDebugLogger.log(.data, "thumbnail signed URL batch failed: \(error.localizedDescription)")
                // Try individual fallback
                for index in updatedItems.indices {
                    if let thumbPath = updatedItems[index].thumbnailPath {
                        do {
                            let url = try await supabase.storage
                                .from("thumbnails")
                                .createSignedURL(path: thumbPath, expiresIn: 3600)
                            updatedItems[index].thumbnailURL = url
                        } catch {
                            // Skip — placeholder will be shown
                        }
                    }
                }
            }
        }

        return updatedItems
    }

    // MARK: - Realtime Subscription

    /// Subscribe to new content in the given S2 cell (for stationary mode).
    /// When the user isn't moving, we listen for server-pushed updates instead of polling.
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

        try? await channel.subscribeWithError()

        // Listen for new content
        Task {
            for await insertion in insertions {
                await handleNewContent(insertion)
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

    private func handleNewContent(_ action: InsertAction) async {
        // The Realtime payload contains the raw row data but not the joined
        // query result (username, distance, signed URL). Rather than trying
        // to reconstruct a partial ContentItem, signal the feed to refresh
        // so it can re-fetch via the full get_nearby_content RPC.
        guard action.record["id"] != nil else { return }

        FeedDebugLogger.log(.data, "⚡ Realtime INSERT detected — posting newNearbyContentAvailable")
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
