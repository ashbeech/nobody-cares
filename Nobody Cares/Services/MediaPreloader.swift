//
//  MediaPreloader.swift
//  Nobody Cares
//
//  Manages a reusable pool of 3 AVPlayers (prev / current / next) and
//  pre-downloads images so adjacent feed items are ready before the user
//  lands on them. Exposes per-index readiness for the paging gate.
//

import AVFoundation
import UIKit

/// All access must happen on the main thread (ensured by UIKit/SwiftUI caller convention).
/// Internal async Tasks use @MainActor continuations for state mutations.
final class MediaPreloader {

    // MARK: - Player Pool (5 slots: ±2 around current)

    private let pool: [AVPlayer] = [AVPlayer(), AVPlayer(), AVPlayer(), AVPlayer(), AVPlayer()]
    private var slotAssignments: [Int: Int] = [:]  // contentIndex → poolSlot

    // MARK: - Preloaded Images (poster frames for video, full images for photos)

    private(set) var images: [Int: UIImage] = [:]

    // MARK: - Readiness Tracking

    private(set) var readiness: [Int: Bool] = [:]

    // MARK: - Internal State

    private var preparationTasks: [Int: Task<Void, Never>] = [:]
    private var loopObservers: [Int: NSObjectProtocol] = [:]

    // MARK: - Data

    private(set) var items: [ContentItem] = []

    /// Fires when an index finishes preparation. Use to hot-swap visible cells.
    var onReadinessChanged: ((_ index: Int, _ ready: Bool) -> Void)?

    // MARK: - Public: Query

    func isReady(_ index: Int) -> Bool {
        readiness[index] == true
    }

    func player(for index: Int) -> AVPlayer? {
        guard let slot = slotAssignments[index] else { return nil }
        return pool[slot]
    }

    func image(for index: Int) -> UIImage? {
        images[index]
    }

    // MARK: - Public: Data

    /// Replace the items list.  Clears resources only for indices whose item ID changed.
    func setItems(_ newItems: [ContentItem]) {
        let oldItems = items
        items = newItems

        var releasedCount = 0
        let maxCount = max(oldItems.count, newItems.count)
        for i in 0..<maxCount {
            let oldId = i < oldItems.count ? oldItems[i].id : nil
            let newId = i < newItems.count ? newItems[i].id : nil
            if oldId != newId {
                release(index: i)
                releasedCount += 1
            }
        }
        FeedDebugLogger.log(.media, "setItems — \(oldItems.count)→\(newItems.count) items, released \(releasedCount) changed indices")
    }

    // MARK: - Public: Buffer Management

    /// Ensure currentIndex ± 2 are being prepared; cancel anything outside that window.
    /// When the feed is small enough to fit entirely in the player pool, keep
    /// *all* items loaded — this avoids releasing content the user already saw
    /// and ensures instant playback when they tap REFRESH to loop back.
    func updateBuffer(around currentIndex: Int) {
        let count = items.count
        guard count > 0 else { return }

        // If every item fits in the pool, keep them all loaded (no eviction).
        let keepAll = count <= pool.count
        let lo = keepAll ? 0 : max(0, currentIndex - 2)
        let hi = keepAll ? count - 1 : min(count - 1, currentIndex + 2)
        let needed = Set(lo...hi)

        // Cancel anything outside the window (skip when keeping everything)
        var releasedOutside = 0
        if !keepAll {
            let allKnown = Set(
                Array(slotAssignments.keys) +
                Array(preparationTasks.keys) +
                Array(readiness.keys)
            )
            for idx in allKnown where !needed.contains(idx) {
                release(index: idx)
                releasedOutside += 1
            }
        }

        let readyInWindow = needed.filter { readiness[$0] == true }.count
        FeedDebugLogger.log(.media, "updateBuffer(around: \(currentIndex)) — window=[\(lo)…\(hi)], keepAll=\(keepAll), ready=\(readyInWindow)/\(needed.count), released=\(releasedOutside) outside")

        // Prepare inside the window (current first, then immediate neighbors, then ±2)
        prepare(index: currentIndex)
        if currentIndex - 1 >= 0 { prepare(index: currentIndex - 1) }
        if currentIndex + 1 < count { prepare(index: currentIndex + 1) }
        if currentIndex - 2 >= 0 { prepare(index: currentIndex - 2) }
        if currentIndex + 2 < count { prepare(index: currentIndex + 2) }

        // When keeping all, also prepare indices outside ±2 that weren't covered above
        if keepAll {
            for idx in 0..<count where abs(idx - currentIndex) > 2 {
                prepare(index: idx)
            }
        }
    }

    // MARK: - Public: Playback Control

    /// Activate playback for the given index and pause all others.
    func activatePlayback(at index: Int, isMuted: Bool, isPaused: Bool) {
        // Pause every assigned player first
        for (_, slot) in slotAssignments {
            pool[slot].pause()
        }

        // Play the target if it's a video
        guard index < items.count, items[index].contentType == .video else { return }
        if let slot = slotAssignments[index] {
            let player = pool[slot]
            player.isMuted = isMuted
            if !isPaused {
                FeedDebugLogger.log(.media, "▶ activatePlayback — index \(index) slot \(slot) (muted=\(isMuted))")
                player.play()
            } else {
                FeedDebugLogger.log(.media, "⏸ activatePlayback — index \(index) slot \(slot) PAUSED")
            }
        } else {
            FeedDebugLogger.log(.media, "activatePlayback — index \(index) has no slot assigned (not ready?)")
        }
    }

    func updateMute(_ isMuted: Bool, currentIndex: Int) {
        guard currentIndex < items.count else { return }
        if let slot = slotAssignments[currentIndex] {
            pool[slot].isMuted = isMuted
        }
    }

    func updatePause(_ isPaused: Bool, currentIndex: Int) {
        guard currentIndex < items.count, items[currentIndex].contentType == .video else { return }
        if let slot = slotAssignments[currentIndex] {
            let player = pool[slot]
            if isPaused {
                player.pause()
            } else {
                player.play()
            }
        }
    }

    // MARK: - Public: Prepare / Cancel Individual

    func prepare(index: Int) {
        guard index >= 0, index < items.count else { return }
        guard readiness[index] != true, preparationTasks[index] == nil else { return }

        let item = items[index]
        FeedDebugLogger.log(.media, "prepare(\(index)) — \(item.contentType.rawValue) id=\(item.id.uuidString.prefix(8))…")

        preparationTasks[index] = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }

            switch item.contentType {
            case .image:
                await self.prepareImage(at: index, url: item.signedURL)
            case .video:
                await self.prepareVideo(at: index, url: item.signedURL)
            }

            self.preparationTasks[index] = nil
        }
    }

    func cancel(index: Int) {
        release(index: index)
    }

    func cancelAll() {
        FeedDebugLogger.log(.media, "cancelAll — releasing \(slotAssignments.count) slots, \(preparationTasks.count) tasks")
        for idx in Array(slotAssignments.keys) { release(index: idx) }
        for (idx, task) in preparationTasks {
            task.cancel()
            preparationTasks[idx] = nil
        }
        images.removeAll()
        readiness.removeAll()
    }

    // MARK: - Private: Image Preparation

    @MainActor
    private func prepareImage(at index: Int, url: URL?) async {
        guard let url else {
            markReady(index)
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            if let img = UIImage(data: data) {
                images[index] = img
            }
        } catch {
            // Non-fatal — cell will show a placeholder
        }

        guard !Task.isCancelled else { return }
        markReady(index)
    }

    // MARK: - Private: Video Preparation

    @MainActor
    private func prepareVideo(at index: Int, url: URL?) async {
        guard let url else {
            markReady(index)
            return
        }

        // 1) Generate first-frame poster (so the cell can display something instantly)
        await generatePoster(at: index, url: url)
        guard !Task.isCancelled else { return }

        // 2) Acquire a pool slot and prime the AVPlayer
        let slot = acquireSlot(for: index)
        let player = pool[slot]

        removeLoopObserver(for: index)

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 3.0

        player.replaceCurrentItem(with: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false

        guard !Task.isCancelled else { return }

        // 3) Wait until AVPlayerItem reaches .readyToPlay (or fails / times out)
        _ = await pollForReady(playerItem)
        guard !Task.isCancelled else { return }

        // 4) Loop observer — seek to start and replay when the item ends
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        loopObservers[index] = observer

        markReady(index)
    }

    @MainActor
    private func generatePoster(at index: Int, url: URL) async {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero
        generator.maximumSize = CGSize(width: 1080, height: 1920)

        if let result = try? await generator.image(at: .zero) {
            guard !Task.isCancelled else { return }
            images[index] = UIImage(cgImage: result.image)
        }
    }

    /// Polls AVPlayerItem.status every 50 ms up to a 10-second timeout.
    @MainActor
    private func pollForReady(_ item: AVPlayerItem) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while item.status == .unknown, Date() < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return item.status == .readyToPlay
    }

    // MARK: - Private: Pool Slot Management

    private func acquireSlot(for contentIndex: Int) -> Int {
        // Already assigned?
        if let slot = slotAssignments[contentIndex] { return slot }

        // Find a free slot
        let used = Set(slotAssignments.values)
        for i in 0..<pool.count where !used.contains(i) {
            slotAssignments[contentIndex] = i
            return i
        }

        // All occupied — evict the farthest content index
        let farthest = slotAssignments.keys
            .sorted { abs($0 - contentIndex) > abs($1 - contentIndex) }
            .first!
        let slot = slotAssignments[farthest]!
        releaseSlot(for: farthest)
        slotAssignments[contentIndex] = slot
        return slot
    }

    // MARK: - Private: Release

    private func release(index: Int) {
        preparationTasks[index]?.cancel()
        preparationTasks[index] = nil
        removeLoopObserver(for: index)
        releaseSlot(for: index)
        images[index] = nil
        readiness[index] = nil
    }

    private func releaseSlot(for contentIndex: Int) {
        guard let slot = slotAssignments[contentIndex] else { return }
        pool[slot].pause()
        pool[slot].replaceCurrentItem(with: nil)
        slotAssignments[contentIndex] = nil
    }

    private func removeLoopObserver(for index: Int) {
        if let obs = loopObservers.removeValue(forKey: index) {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Private: Readiness

    @MainActor
    private func markReady(_ index: Int) {
        let type = index < items.count ? items[index].contentType.rawValue : "?"
        FeedDebugLogger.log(.media, "✅ markReady(\(index)) — \(type)")
        readiness[index] = true
        onReadinessChanged?(index, true)
    }
}
