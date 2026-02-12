//
//  FeedViewModel.swift
//  Nobody Cares
//
//  Manages the full feed lifecycle:
//  - Location-driven content fetching via FeedDataService
//  - 6-second auto-advance timer with progress bar
//  - Press-and-hold pause
//  - Mute state persistence within session
//  - Content visibility hysteresis (enter 10m, exit 14m, 3s sticky)
//  - Movement-triggered refresh and Realtime subscription for stationary mode
//  - MediaPreloader integration for adjacent-item preloading
//

import SwiftUI

// MARK: - Feed State

enum FeedState: Equatable {
    case loading
    case empty
    case content
    case endOfFeed
    case error(String)

    static func == (lhs: FeedState, rhs: FeedState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading),
             (.empty, .empty),
             (.content, .content),
             (.endOfFeed, .endOfFeed):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Content Visibility (Hysteresis)

enum ContentVisibility: Equatable {
    case visible      // within 10m
    case exiting      // between 10m-14m, 3s countdown to hide
    case hidden       // beyond 14m or countdown expired
}

// MARK: - Feed View Model

@Observable
final class FeedViewModel {
    // MARK: - State

    var feedState: FeedState = .loading
    var items: [ContentItem] = []
    var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue {
                mediaPreloader.updateBuffer(around: currentIndex)
            }
        }
    }
    var isMuted: Bool = true
    var isPaused: Bool = false
    var progress: Double = 0.0
    var isRefreshing: Bool = false
    var showEndOfFeedAlert: Bool = false

    // MARK: - Services

    let locationService = LocationService()
    let feedDataService = FeedDataService()
    let mediaPreloader = MediaPreloader()

    // MARK: - Private

    private var autoAdvanceTimer: Timer?
    private var progressTimer: Timer?
    private var hysteresisTimers: [UUID: Timer] = [:]
    private var itemVisibility: [UUID: ContentVisibility] = [:]
    private let autoAdvanceDuration: TimeInterval = 6.0
    private let progressInterval: TimeInterval = 1.0 / 60.0 // 60fps
    private let enterRadius: Double = 10.0
    private let exitRadius: Double = 14.0
    private let stickyDelay: TimeInterval = 3.0

    // MARK: - Computed

    var currentItem: ContentItem? {
        guard !items.isEmpty, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    var hasContent: Bool {
        !items.isEmpty
    }

    // MARK: - Lifecycle

    func startFeed() {
        FeedDebugLogger.log(.feed, "startFeed() called — setting state to .loading")
        feedState = .loading

        // Set up location callbacks
        locationService.onSignificantMovement = { [weak self] in
            Task { @MainActor in
                FeedDebugLogger.log(.feed, "⚡ onSignificantMovement callback — triggering refreshFromLocation")
                await self?.refreshFromLocation()
            }
        }

        locationService.onBecameStationary = { [weak self] in
            Task { @MainActor in
                FeedDebugLogger.log(.feed, "⚡ onBecameStationary callback — switching to Realtime mode")
                await self?.switchToRealtimeMode()
            }
        }

        // Listen for Realtime new-content notifications
        NotificationCenter.default.addObserver(
            forName: .newNearbyContentAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                FeedDebugLogger.log(.feed, "⚡ Realtime notification: newNearbyContentAvailable — refreshing")
                await self?.refreshFromLocation()
            }
        }

        // Start location monitoring
        locationService.startMonitoring()
        FeedDebugLogger.log(.feed, "Location monitoring started")

        // Initial load with a brief delay for first location fix
        Task {
            FeedDebugLogger.log(.feed, "Waiting 1s for first GPS fix…")
            // Wait briefly for first GPS fix
            try? await Task.sleep(for: .seconds(1))
            FeedDebugLogger.log(.feed, "GPS wait complete — calling refreshFromLocation")
            await refreshFromLocation()
        }
    }

    func stopFeed() {
        FeedDebugLogger.log(.feed, "stopFeed() — tearing down location, timers, preloader")
        locationService.stopMonitoring()
        stopAutoAdvance()
        mediaPreloader.cancelAll()
        Task { await feedDataService.unsubscribeFromCell() }
    }

    // MARK: - Content Fetching

    @MainActor
    private func refreshFromLocation() async {
        // Don't refresh while the end-of-feed alert is showing.
        // Background events (location, Realtime) must not mutate feed state
        // underneath the alert — the user must act first.
        guard !showEndOfFeedAlert else {
            FeedDebugLogger.log(.feed, "refreshFromLocation — SKIPPED (endOfFeedAlert is showing)")
            return
        }

        guard let location = locationService.currentLocation else {
            FeedDebugLogger.log(.feed, "refreshFromLocation — no currentLocation, attempting fetchCurrentLocation")
            // Try to get a location
            let fetched = await locationService.fetchCurrentLocation()
            if fetched == nil {
                FeedDebugLogger.log(.feed, "refreshFromLocation — fetchCurrentLocation FAILED, showing error")
                AnalyticsService.shared.track(.locationUnavailable, metadata: ["source": "feed"])
                feedState = .error("NO SIGNAL. CONTENT IS PATIENT. Move to an area with GPS signal.")
            } else {
                FeedDebugLogger.log(.feed, "refreshFromLocation — fetchCurrentLocation succeeded, but returning (will retry)")
            }
            return
        }

        let radius = locationService.effectiveRadius
        FeedDebugLogger.log(.feed, "refreshFromLocation — lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) radius=\(radius)m")

        await feedDataService.refresh(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radius: radius
        )

        if let error = feedDataService.error {
            FeedDebugLogger.log(.feed, "refreshFromLocation — ERROR: \(error)", detail: "existingItems=\(items.count)")
            AnalyticsService.shared.track(.networkError, metadata: ["source": "feed", "error": error])
            if items.isEmpty {
                feedState = .error("NO SIGNAL. CONTENT IS PATIENT. Check your connection and try again.")
            }
            // If we already have content, silently ignore the error
        } else if feedDataService.items.isEmpty {
            if !items.isEmpty {
                // GPS jitter guard: we had content, but this refresh returned nothing.
                // Indoor GPS can drift 10-65m, pushing us outside the small radius.
                // Keep existing content instead of flashing the empty state.
                FeedDebugLogger.log(.feed, "refreshFromLocation — EMPTY result but had \(items.count) items → KEEPING existing content (GPS jitter guard)")
            } else {
                FeedDebugLogger.log(.feed, "refreshFromLocation — EMPTY result (first load), showing empty state")
                feedState = .empty
            }
        } else {
            let hadContent = !items.isEmpty
            let newItems = feedDataService.items
            FeedDebugLogger.log(.feed, "refreshFromLocation — GOT \(newItems.count) items (had \(items.count))", detail: "hadContent=\(hadContent)")
            for (i, item) in newItems.enumerated() {
                FeedDebugLogger.log(.feed, "  [\(i)] \(item.contentType.rawValue) id=\(item.id.uuidString.prefix(8))… dist=\(String(format: "%.1f", item.distanceMeters))m @\(item.username)")
            }

            mediaPreloader.setItems(newItems)
            items = newItems

            // Clear end-of-feed alert if new content appeared
            if showEndOfFeedAlert { showEndOfFeedAlert = false }

            if hadContent {
                // Smart: preserve current index if in bounds
                if currentIndex >= items.count {
                    let oldIdx = currentIndex
                    currentIndex = max(0, items.count - 1)
                    FeedDebugLogger.log(.feed, "refreshFromLocation — clamped currentIndex \(oldIdx)→\(currentIndex)")
                }
                mediaPreloader.updateBuffer(around: currentIndex)
            } else {
                currentIndex = 0
                progress = 0.0
                feedState = .content
                FeedDebugLogger.log(.feed, "refreshFromLocation — first load, starting auto-advance from index 0")
                mediaPreloader.updateBuffer(around: 0)
                startAutoAdvance()
            }
        }
    }

    // MARK: - Smart Refresh (pull-to-refresh: don't reload identical content, never flash)

    @MainActor
    func smartRefresh() {
        guard !isRefreshing else {
            FeedDebugLogger.log(.feed, "smartRefresh — SKIPPED (already refreshing)")
            return
        }
        isRefreshing = true
        FeedDebugLogger.log(.feed, "smartRefresh — START (pull-to-refresh)")

        Task {
            defer {
                isRefreshing = false
                FeedDebugLogger.log(.feed, "smartRefresh — DONE")
            }

            guard let location = locationService.currentLocation else {
                FeedDebugLogger.log(.feed, "smartRefresh — no location available")
                let fetched = await locationService.fetchCurrentLocation()
                if fetched == nil && items.isEmpty {
                    feedState = .error("NO SIGNAL. CONTENT IS PATIENT. Move to an area with GPS signal.")
                }
                return
            }

            let radius = locationService.effectiveRadius
            FeedDebugLogger.log(.feed, "smartRefresh — fetching at lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) r=\(radius)m")

            do {
                let newItems = try await feedDataService.fetchNearbyContent(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    radius: radius
                )

                let existingIds = items.map(\.id)
                let newIds = newItems.map(\.id)

                if existingIds == newIds {
                    FeedDebugLogger.log(.feed, "smartRefresh — SAME \(newItems.count) items (URLs refreshed silently)")
                    // Same items — silently update signed URLs without any visual change
                    mediaPreloader.setItems(newItems)
                    items = newItems
                    // Don't clear end-of-feed alert — content is identical
                } else if newItems.isEmpty {
                    FeedDebugLogger.log(.feed, "smartRefresh — EMPTY result (was \(items.count))")
                    items = []
                    mediaPreloader.cancelAll()
                    feedState = .empty
                } else {
                    FeedDebugLogger.log(.feed, "smartRefresh — DIFFERENT content: \(items.count)→\(newItems.count) items")
                    for (i, item) in newItems.enumerated() {
                        FeedDebugLogger.log(.feed, "  [\(i)] \(item.contentType.rawValue) id=\(item.id.uuidString.prefix(8))… dist=\(String(format: "%.1f", item.distanceMeters))m")
                    }

                    // Different content — update in-place
                    if showEndOfFeedAlert { showEndOfFeedAlert = false }
                    let currentItemId = currentIndex < items.count ? items[currentIndex].id : nil

                    mediaPreloader.setItems(newItems)
                    items = newItems

                    // Try to keep the user on the same item
                    if let cid = currentItemId,
                       let newIdx = newItems.firstIndex(where: { $0.id == cid }) {
                        FeedDebugLogger.log(.feed, "smartRefresh — preserved position at index \(newIdx)")
                        currentIndex = newIdx
                    } else {
                        FeedDebugLogger.log(.feed, "smartRefresh — current item gone, resetting to index 0")
                        currentIndex = 0
                    }

                    if feedState != .content {
                        feedState = .content
                        startAutoAdvance()
                    }

                    mediaPreloader.updateBuffer(around: currentIndex)
                }

                feedDataService.items = newItems
                feedDataService.error = nil
            } catch {
                FeedDebugLogger.log(.feed, "smartRefresh — NETWORK ERROR: \(error.localizedDescription)")
                // Don't overwrite existing content on error
                if items.isEmpty {
                    feedState = .error("NO SIGNAL. CONTENT IS PATIENT. Check your connection and try again.")
                }
            }
        }
    }

    // MARK: - Auto-Advance Timer

    func startAutoAdvance() {
        // Never start a timer when there's no content to advance through.
        // This prevents the timer from firing on the empty/error view and
        // accidentally triggering showEndOfFeedAlert.
        guard feedState == .content, !items.isEmpty else {
            FeedDebugLogger.log(.feed, "startAutoAdvance — SKIPPED (state=\(feedState), items=\(items.count))")
            return
        }

        stopAutoAdvance()
        progress = 0.0
        FeedDebugLogger.log(.feed, "⏱ startAutoAdvance — 6s timer started at index \(currentIndex)/\(items.count - 1)")

        // Progress update at ~60fps
        progressTimer = Timer.scheduledTimer(withTimeInterval: progressInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.progress += self.progressInterval / self.autoAdvanceDuration
                if self.progress >= 1.0 {
                    self.advanceToNext()
                }
            }
        }
    }

    func stopAutoAdvance() {
        if progressTimer != nil || autoAdvanceTimer != nil {
            FeedDebugLogger.log(.feed, "⏱ stopAutoAdvance — timers invalidated")
        }
        progressTimer?.invalidate()
        progressTimer = nil
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    // MARK: - Navigation

    func advanceToNext() {
        // Never auto-advance on an empty feed — nothing to advance to.
        guard !items.isEmpty else {
            FeedDebugLogger.log(.feed, "advanceToNext — SKIPPED (empty feed)")
            stopAutoAdvance()
            return
        }

        // Track view of current item before advancing
        if let item = currentItem {
            AnalyticsService.shared.track(.contentViewed, metadata: [
                "content_id": item.id.uuidString,
                "content_type": item.contentType.rawValue,
            ])
        }

        guard currentIndex < items.count - 1 else {
            // At last item — stop timer permanently, show end-of-feed alert.
            // Content keeps looping in background; no navigation or restart.
            FeedDebugLogger.log(.feed, "▶ advanceToNext — REACHED END at index \(currentIndex)/\(items.count - 1), showing endOfFeedAlert")
            stopAutoAdvance()
            progress = 0.0
            showEndOfFeedAlert = true
            return
        }

        // Readiness gate for auto-advance only: don't advance onto an unprepared item.
        // The timer keeps firing so this retries every frame until ready.
        guard mediaPreloader.isReady(currentIndex + 1) else {
            // Only log once per second to avoid spam (progress is near 1.0)
            return
        }

        FeedDebugLogger.log(.feed, "▶ advanceToNext — \(currentIndex)→\(currentIndex + 1) of \(items.count)")

        // Stop the timer now. It will be restarted by onPagerScrollSettled
        // once the scroll animation completes — giving a clean 6-second window.
        stopAutoAdvance()

        currentIndex += 1
        progress = 0.0
    }

    func goToPrevious() {
        guard currentIndex > 0 else { return }
        FeedDebugLogger.log(.feed, "◀ goToPrevious — \(currentIndex)→\(currentIndex - 1)")
        currentIndex -= 1
        progress = 0.0
    }

    func refresh() {
        FeedDebugLogger.log(.feed, "refresh() called — items=\(items.count)")
        if items.isEmpty {
            // No existing content — show loading
            feedState = .loading
        }
        currentIndex = 0
        progress = 0.0
        Task { await refreshFromLocation() }
    }

    func toggleMute() {
        isMuted.toggle()
        FeedDebugLogger.log(.feed, "toggleMute → \(isMuted ? "MUTED" : "UNMUTED")")
    }

    func goToFirst() {
        guard !items.isEmpty else { return }
        FeedDebugLogger.log(.feed, "goToFirst — jumping to index 0 from \(currentIndex)")
        currentIndex = 0
        progress = 0.0
        feedState = .content
        startAutoAdvance()
    }

    func goToLast() {
        guard !items.isEmpty else { return }
        FeedDebugLogger.log(.feed, "goToLast — jumping to index \(items.count - 1) from \(currentIndex)")
        currentIndex = items.count - 1
        progress = 0.0
        feedState = .content
        startAutoAdvance()
    }

    func setPaused(_ paused: Bool) {
        FeedDebugLogger.log(.feed, "setPaused(\(paused))")
        isPaused = paused
    }

    // MARK: - Pager Callbacks (called from FeedPagerViewController via bridge)

    /// The pager's scroll settled on a new index.
    func onPagerIndexChanged(_ index: Int) {
        guard index != currentIndex else { return }
        FeedDebugLogger.log(.feed, "onPagerIndexChanged — \(currentIndex)→\(index)")
        currentIndex = index
        progress = 0.0

        // User navigated away from last item — clear end-of-feed alert
        if showEndOfFeedAlert {
            FeedDebugLogger.log(.feed, "onPagerIndexChanged — clearing endOfFeedAlert")
            showEndOfFeedAlert = false
        }
        // Auto-advance is restarted by onPagerScrollSettled (always fires)
    }

    /// The user started dragging — stop all timers/animation cleanly.
    func onPagerDragBegan() {
        FeedDebugLogger.log(.feed, "onPagerDragBegan — user started swiping, stopping timers")
        stopAutoAdvance()
    }

    /// The pager's scroll finished (fired regardless of whether index changed).
    /// Always restarts auto-advance with a fresh 6-second window
    /// unless the end-of-feed alert is active or a refresh is in flight.
    func onPagerScrollSettled() {
        guard feedState == .content, !items.isEmpty else {
            FeedDebugLogger.log(.feed, "onPagerScrollSettled — SKIPPED (state=\(feedState), items=\(items.count))")
            return
        }
        guard !showEndOfFeedAlert else {
            FeedDebugLogger.log(.feed, "onPagerScrollSettled — SKIPPED (endOfFeedAlert showing)")
            return
        }
        guard !isRefreshing else {
            FeedDebugLogger.log(.feed, "onPagerScrollSettled — SKIPPED (refreshing)")
            return
        }
        FeedDebugLogger.log(.feed, "onPagerScrollSettled — restarting auto-advance at index \(currentIndex)")
        startAutoAdvance()
    }

    /// Called when user dismisses the "NO MORE LOCAL CONTENT" alert
    /// via close button or backdrop tap (no refresh).
    func dismissEndOfFeedAlert() {
        FeedDebugLogger.log(.feed, "dismissEndOfFeedAlert — user dismissed without refresh")
        showEndOfFeedAlert = false
        // Don't restart auto-advance — user is on last item, nowhere to go.
        // They can swipe back or pull-to-refresh to find new content.
    }

    /// Called when user taps REFRESH on the end-of-feed alert.
    /// Dismisses the alert, resets to index 0, fetches fresh content.
    /// If content exists: shows it with auto-advance.
    /// If no content: shows the empty state.
    func refreshFeedFromAlert() {
        FeedDebugLogger.log(.feed, "refreshFeedFromAlert — user tapped REFRESH on endOfFeed alert")
        showEndOfFeedAlert = false
        stopAutoAdvance()
        progress = 0.0

        // Mark refreshing *before* changing currentIndex so that
        // onPagerScrollSettled (fired when the scroll animation lands)
        // won't restart the auto-advance timer mid-refresh.
        isRefreshing = true

        // Reset to first page. This triggers a programmatic scroll via
        // updateUIViewController → scrollToIndex(0). The scroll's
        // onScrollSettled is gated by isRefreshing above.
        currentIndex = 0

        Task { @MainActor in
            defer { isRefreshing = false }

            // Resolve location: prefer cached, fall back to a fresh fix
            var location = locationService.currentLocation
            if location == nil {
                location = await locationService.fetchCurrentLocation()
            }

            guard let location else {
                // No location at all. Keep existing content if we have it.
                if !items.isEmpty {
                    feedState = .content
                    startAutoAdvance()
                } else {
                    feedState = .empty
                }
                return
            }

            await performRefreshFetch(latitude: location.coordinate.latitude,
                                      longitude: location.coordinate.longitude)
        }
    }

    /// Shared fetch logic for refreshFeedFromAlert.
    /// Uses fetchNearbyContent directly (not feedDataService.refresh)
    /// so we can preserve existing content on network errors.
    @MainActor
    private func performRefreshFetch(latitude: Double, longitude: Double) async {
        let radius = locationService.effectiveRadius

        do {
            let newItems = try await feedDataService.fetchNearbyContent(
                latitude: latitude,
                longitude: longitude,
                radius: radius
            )

            if newItems.isEmpty {
                items = []
                mediaPreloader.cancelAll()
                feedState = .empty
            } else {
                mediaPreloader.setItems(newItems)
                items = newItems
                currentIndex = 0
                feedState = .content
                mediaPreloader.updateBuffer(around: 0)
                startAutoAdvance()

                // Keep feedDataService in sync
                feedDataService.items = newItems
                feedDataService.error = nil
            }
        } catch {
            // Network error — preserve existing content if we have it
            if !items.isEmpty {
                currentIndex = 0
                feedState = .content
                mediaPreloader.updateBuffer(around: 0)
                startAutoAdvance()
            } else {
                feedState = .error("NO SIGNAL. CONTENT IS PATIENT. Check your connection and try again.")
            }
        }
    }

    // MARK: - Private: Load More

    @MainActor
    private func tryLoadMore() async {
        guard let location = locationService.currentLocation else { return }
        await feedDataService.loadMore(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radius: locationService.effectiveRadius
        )
        if feedDataService.items.count > items.count {
            let newItems = feedDataService.items
            mediaPreloader.setItems(newItems)
            items = newItems
            mediaPreloader.updateBuffer(around: currentIndex)
            // New content arrived — clear alert and resume auto-advance
            if showEndOfFeedAlert { showEndOfFeedAlert = false }
            startAutoAdvance()
        }
    }

    // MARK: - Realtime Mode

    @MainActor
    private func switchToRealtimeMode() async {
        guard let location = locationService.currentLocation else {
            FeedDebugLogger.log(.feed, "switchToRealtimeMode — no location, skipping")
            return
        }

        let cellId = S2CellCalculator.cellId(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        FeedDebugLogger.log(.feed, "switchToRealtimeMode — subscribing to cell \(cellId)")
        await feedDataService.subscribeToCell(cellId: cellId)
    }

    // MARK: - Content Visibility Hysteresis

    /// Update visibility for an item based on current distance.
    /// Enter at 10m, exit at 14m with 3s sticky delay.
    func updateVisibility(for item: ContentItem, currentDistance: Double) -> ContentVisibility {
        let currentVisibility = itemVisibility[item.id] ?? .hidden

        switch currentVisibility {
        case .hidden:
            if currentDistance <= enterRadius {
                itemVisibility[item.id] = .visible
                return .visible
            }
            return .hidden

        case .visible:
            if currentDistance > exitRadius {
                // Start exiting countdown
                itemVisibility[item.id] = .exiting
                startExitTimer(for: item.id)
                return .exiting
            }
            return .visible

        case .exiting:
            if currentDistance <= enterRadius {
                // Came back within range — cancel exit
                cancelExitTimer(for: item.id)
                itemVisibility[item.id] = .visible
                return .visible
            }
            // Still in exit countdown
            return .exiting
        }
    }

    private func startExitTimer(for itemId: UUID) {
        hysteresisTimers[itemId]?.invalidate()
        hysteresisTimers[itemId] = Timer.scheduledTimer(withTimeInterval: stickyDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.itemVisibility[itemId] = .hidden
                self?.hysteresisTimers[itemId] = nil
                // If the now-hidden item is the current one, advance
                if self?.currentItem?.id == itemId {
                    self?.advanceToNext()
                }
            }
        }
    }

    private func cancelExitTimer(for itemId: UUID) {
        hysteresisTimers[itemId]?.invalidate()
        hysteresisTimers[itemId] = nil
    }
}
