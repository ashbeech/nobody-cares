//
//  FeedViewModel.swift
//  Nobody Cares
//
//  Manages the full feed lifecycle:
//  - Location-driven content fetching via FeedDataService
//  - 6-second auto-advance timer with progress bar
//  - Press-and-hold pause
//  - Mute state persistence within session
//  - Realtime proximity awareness with smoothed location + hysteresis
//  - Display updates (cheap, every location) vs server refresh (expensive, movement-triggered)
//  - MediaPreloader integration for adjacent-item preloading
//

import SwiftUI
import CoreLocation

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

// MARK: - Range State (Proximity Awareness)

enum RangeState: Equatable {
    case inRange      // distance ≤ enterRadius — playback allowed
    case gracePeriod  // distance ≥ exitRadius, waiting exitHoldSeconds before removal
    case outOfRange   // confirmed out — item will be removed from feed
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
    var isTimerPaused: Bool = false
    var showEndOfFeedAlert: Bool = false

    /// Per-item range states for proximity overlays. Published so the pager can observe.
    var itemRangeStates: [UUID: RangeState] = [:]

    // MARK: - Services

    let locationService = LocationService()
    let feedDataService = FeedDataService()
    let mediaPreloader = MediaPreloader()

    // MARK: - Private

    private var autoAdvanceTimer: Timer?
    private var progressTimer: Timer?
    private var isLocationRefreshInFlight = false
    private var exitTimers: [UUID: Task<Void, Never>] = [:]

    /// Prevents duplicate initial refresh at startup
    private var hasCompletedInitialRefresh = false

    /// Query radius ratchet: once content is found at a wider radius
    /// (due to momentarily poor accuracy), don't shrink the radius when
    /// accuracy later improves. Reset in startFeed().
    private var sessionMaxRadius: Double = 10.0

    // MARK: - Location: UI vs Logic (separate positions)
    //
    // uiLocation (smoothed): weighted average of recent fixes, for radar dot / UI.
    // logicLocation (conservative): only updated with high-quality fixes (accuracy ≤ 15m).
    //   Used exclusively for range state transitions and server re-query decisions.
    //   This separation prevents GPS jitter from flipping range states while still
    //   keeping the UI dot smooth.

    private var recentLocations: [CLLocation] = []
    private let smoothingWindowSize = 5
    private var smoothedLocation: CLLocation?    // for UI
    private var logicLocation: CLLocation?       // for range checks — trusted fixes only

    /// Per-item: how many consecutive location updates have computed distance
    /// beyond the exit threshold. Requires 3+ (5 when stationary) before
    /// transitioning to gracePeriod.
    private var exitConfirmationCounts: [UUID: Int] = [:]

    // MARK: - Constants

    private let autoAdvanceDuration: TimeInterval = 6.0
    private let progressInterval: TimeInterval = 1.0 / 60.0 // 60fps

    // Proximity thresholds — deliberately wide to absorb GPS jitter.
    // Urban GPS accuracy is typically 5-15m; tight thresholds cause
    // constant false "Leaving range" transitions from normal signal noise.
    let enterRadiusMeters: Double = 12.0
    let exitRadiusMeters: Double = 20.0   // 8m buffer above enter
    let exitHoldSeconds: TimeInterval = 12.0  // must stay beyond exit for 12s before removal

    /// Confirmations required before transitioning inRange → gracePeriod.
    private let exitConfirmationsRequired = 3
    private let exitConfirmationsRequiredStationary = 5

    // MARK: - Computed

    var currentItem: ContentItem? {
        guard !items.isEmpty, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    var hasContent: Bool {
        !items.isEmpty
    }

    /// Returns the effective query radius, ratcheted so it never shrinks.
    private func queryRadius() -> Double {
        let effective = locationService.effectiveRadius
        sessionMaxRadius = max(sessionMaxRadius, effective)
        return sessionMaxRadius
    }

    // MARK: - Lifecycle

    func startFeed() {
        FeedDebugLogger.log(.feed, "startFeed() called — setting state to .loading")
        feedState = .loading
        sessionMaxRadius = 10.0
        hasCompletedInitialRefresh = false
        recentLocations = []
        smoothedLocation = nil
        logicLocation = nil
        itemRangeStates = [:]
        exitConfirmationCounts = [:]

        // Set up location callbacks

        // Display updates: fired on EVERY location update (cheap)
        locationService.onLocationUpdate = { [weak self] location in
            Task { @MainActor in
                self?.handleDisplayUpdate(location)
            }
        }

        // Server refresh: fired only on significant movement (expensive)
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
            try? await Task.sleep(for: .seconds(1))

            // Fix double-refresh: skip if first location callback already triggered refresh
            guard !hasCompletedInitialRefresh else {
                FeedDebugLogger.log(.feed, "GPS wait complete — initial refresh already done, skipping")
                return
            }

            FeedDebugLogger.log(.feed, "GPS wait complete — calling refreshFromLocation")
            await refreshFromLocation()
        }
    }

    func stopFeed() {
        FeedDebugLogger.log(.feed, "stopFeed() — tearing down location, timers, preloader")
        locationService.stopMonitoring()
        stopAutoAdvance()
        mediaPreloader.cancelAll()
        cancelAllExitTimers()
        Task { await feedDataService.unsubscribeFromCell() }
    }

    // MARK: - Display Update (every location — cheap, local only)

    @MainActor
    private func handleDisplayUpdate(_ location: CLLocation) {
        let accuracy = location.horizontalAccuracy

        // Reject obviously bad fixes — don't drive any state from them
        guard accuracy > 0, accuracy <= 50 else { return }

        // Always update the smoothed location for UI (radar dot, etc.)
        recentLocations.append(location)
        if recentLocations.count > smoothingWindowSize {
            recentLocations.removeFirst()
        }
        smoothedLocation = computeSmoothedLocation()

        // Logic location: only update with high-quality fixes (accuracy ≤ 15m).
        // This prevents GPS jitter from poisoning range state decisions.
        if accuracy <= 15 {
            logicLocation = location
        }

        // Range state transitions: only use the trusted logic location.
        // If we haven't gotten a good fix yet, don't compute range states at all.
        guard let logic = logicLocation else { return }

        // Don't recompute from a stale logic location (> 30s old)
        guard abs(logic.timestamp.timeIntervalSinceNow) < 30 else { return }

        updateRangeStates(from: logic)
    }

    /// Compute weighted average of recent locations.
    /// Weight each by 1 / max(1, horizontalAccuracy).
    private func computeSmoothedLocation() -> CLLocation? {
        guard !recentLocations.isEmpty else { return nil }

        var totalWeight: Double = 0
        var weightedLat: Double = 0
        var weightedLng: Double = 0

        for loc in recentLocations {
            let weight = 1.0 / max(1.0, loc.horizontalAccuracy)
            weightedLat += loc.coordinate.latitude * weight
            weightedLng += loc.coordinate.longitude * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return recentLocations.last }

        return CLLocation(
            latitude: weightedLat / totalWeight,
            longitude: weightedLng / totalWeight
        )
    }

    /// Recompute range state for every item in the feed based on logic location (trusted fix).
    @MainActor
    private func updateRangeStates(from location: CLLocation) {
        guard !items.isEmpty else { return }

        var stateChanged = false
        for item in items {
            guard let capLat = item.captureLat, let capLng = item.captureLng else { continue }

            let captureLocation = CLLocation(latitude: capLat, longitude: capLng)
            let distance = location.distance(from: captureLocation)
            let oldState = itemRangeStates[item.id] ?? .inRange

            let newState = computeRangeTransition(
                itemId: item.id,
                distance: distance,
                currentState: oldState
            )

            if newState != oldState {
                itemRangeStates[item.id] = newState
                stateChanged = true
                FeedDebugLogger.log(.feed, "🎯 rangeState — \(item.id.uuidString.prefix(8))… dist=\(String(format: "%.1f", distance))m \(oldState)→\(newState)")
            }
        }

        // If any state changed, the pager bridge will pick it up via observation
        if stateChanged {
            // Check if current item playback should change
            if let current = currentItem {
                let currentRange = itemRangeStates[current.id] ?? .inRange
                FeedDebugLogger.log(.feed, "🎯 current item range=\(currentRange) (index=\(currentIndex))")
            }
        }
    }

    /// Whether the user is stationary based on CLLocation.speed.
    private var isStationary: Bool {
        guard let speed = locationService.currentLocation?.speed, speed >= 0 else { return false }
        return speed < 0.5
    }

    /// State machine for a single item's range transition with hysteresis.
    /// Requires multiple consecutive beyond-exit readings before starting the
    /// grace period (3 normally, 5 when stationary). This prevents GPS jitter
    /// from triggering false "Leaving range" transitions.
    private func computeRangeTransition(
        itemId: UUID,
        distance: Double,
        currentState: RangeState
    ) -> RangeState {
        let needed = isStationary ? exitConfirmationsRequiredStationary : exitConfirmationsRequired

        switch currentState {
        case .inRange:
            if distance >= exitRadiusMeters {
                // Increment confirmation counter
                let count = (exitConfirmationCounts[itemId] ?? 0) + 1
                exitConfirmationCounts[itemId] = count
                if count >= needed {
                    // Confirmed: start grace period (exit timer will remove if sustained)
                    exitConfirmationCounts[itemId] = nil
                    startExitTimer(for: itemId)
                    return .gracePeriod
                }
                // Not yet confirmed — stay inRange, wait for more readings
                return .inRange
            }
            // Back within range — reset confirmation counter
            exitConfirmationCounts[itemId] = nil
            return .inRange

        case .gracePeriod:
            if distance <= enterRadiusMeters {
                // Came back within range — cancel exit
                cancelExitTimer(for: itemId)
                exitConfirmationCounts[itemId] = nil
                return .inRange
            }
            // Stay in grace period — the exit timer will resolve it
            return .gracePeriod

        case .outOfRange:
            // outOfRange items should have been removed from the feed.
            // If we somehow still see one, let it re-enter on proximity.
            if distance <= enterRadiusMeters {
                cancelExitTimer(for: itemId)
                exitConfirmationCounts[itemId] = nil
                return .inRange
            }
            return .outOfRange
        }
    }

    // MARK: - Exit Timers (hysteresis)

    private func startExitTimer(for itemId: UUID) {
        cancelExitTimer(for: itemId)
        exitTimers[itemId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.exitHoldSeconds ?? 12.0))
            guard !Task.isCancelled, let self else { return }

            // Re-check distance with latest logic location (not smoothed — avoids drift)
            guard let logic = self.logicLocation,
                  let item = self.items.first(where: { $0.id == itemId }),
                  let capLat = item.captureLat,
                  let capLng = item.captureLng else {
                return
            }

            let captureLocation = CLLocation(latitude: capLat, longitude: capLng)
            let distance = logic.distance(from: captureLocation)

            if distance >= self.exitRadiusMeters {
                // Confirmed out — remove from feed entirely
                FeedDebugLogger.log(.feed, "🗑 exitTimer — \(itemId.uuidString.prefix(8))… confirmed outOfRange (dist=\(String(format: "%.1f", distance))m) → removing from feed")
                self.removeItemFromFeed(itemId)
            } else {
                // Came back — restore inRange
                self.itemRangeStates[itemId] = .inRange
                FeedDebugLogger.log(.feed, "🎯 exitTimer — \(itemId.uuidString.prefix(8))… back inRange (dist=\(String(format: "%.1f", distance))m)")
            }

            self.exitTimers[itemId] = nil
        }
    }

    private func cancelExitTimer(for itemId: UUID) {
        exitTimers[itemId]?.cancel()
        exitTimers[itemId] = nil
    }

    private func cancelAllExitTimers() {
        for (_, task) in exitTimers { task.cancel() }
        exitTimers.removeAll()
    }

    // MARK: - Item Removal (outOfRange items leave the feed)

    /// Remove an item from the feed entirely. Called when exit timer confirms
    /// the item is truly out of range, or when a refresh excludes it.
    @MainActor
    private func removeItemFromFeed(_ itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }

        FeedDebugLogger.log(.feed, "🗑 removing \(itemId.uuidString.prefix(8))… from feed (index \(idx), \(items.count) items → \(items.count - 1))")

        // Clean up state tracking
        itemRangeStates[itemId] = nil
        exitConfirmationCounts[itemId] = nil
        cancelExitTimer(for: itemId)

        // Remove from items array
        items.remove(at: idx)

        if items.isEmpty {
            currentIndex = 0
            mediaPreloader.cancelAll()
            stopAutoAdvance()
            feedState = .empty
            FeedDebugLogger.log(.feed, "🗑 feed is now empty after removal")
            return
        }

        // Adjust currentIndex to keep user on the same content
        if idx < currentIndex {
            // Removed item was before current — shift index back
            currentIndex = max(0, currentIndex - 1)
        } else if idx == currentIndex {
            // Removed the current item — stay at same index (now shows next item)
            // or clamp to the last item if we were at the end
            currentIndex = min(currentIndex, items.count - 1)
        }
        // else: removed item was after current, no index change needed

        mediaPreloader.setItems(items)
        mediaPreloader.updateBuffer(around: currentIndex)

        // Restart auto-advance (may now advance past the removed gap)
        if feedState == .content && !isPaused {
            startAutoAdvance()
        }
    }

    // MARK: - Content Fetching

    @MainActor
    private func refreshFromLocation() async {
        // Don't refresh while the end-of-feed alert is showing.
        guard !showEndOfFeedAlert else {
            FeedDebugLogger.log(.feed, "refreshFromLocation — SKIPPED (endOfFeedAlert is showing)")
            return
        }

        // Prevent concurrent location refreshes
        guard !isLocationRefreshInFlight else {
            FeedDebugLogger.log(.feed, "refreshFromLocation — SKIPPED (refresh already in flight)")
            return
        }
        isLocationRefreshInFlight = true
        defer { isLocationRefreshInFlight = false }

        guard let location = locationService.currentLocation else {
            FeedDebugLogger.log(.feed, "refreshFromLocation — no currentLocation, attempting fetchCurrentLocation")
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

        let radius = queryRadius()
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
        } else if feedDataService.items.isEmpty {
            // GPS jitter guard: only keep existing content if accuracy is very poor.
            // With good accuracy, an empty result is genuine — show empty state.
            let accuracy = location.horizontalAccuracy
            if !items.isEmpty && accuracy > 50 {
                FeedDebugLogger.log(.feed, "refreshFromLocation — EMPTY result but had \(items.count) items and poor accuracy (\(String(format: "%.0f", accuracy))m) → KEEPING existing content")
            } else if !items.isEmpty {
                FeedDebugLogger.log(.feed, "refreshFromLocation — EMPTY result (accuracy \(String(format: "%.0f", accuracy))m is OK), accepting empty")
                items = []
                mediaPreloader.cancelAll()
                cancelAllExitTimers()
                itemRangeStates.removeAll()
                exitConfirmationCounts.removeAll()
                feedState = .empty
            } else {
                FeedDebugLogger.log(.feed, "refreshFromLocation — EMPTY result (first load), showing empty state")
                feedState = .empty
            }
        } else {
            let hadContent = !items.isEmpty
            let allItems = feedDataService.items

            // Filter: only include items within exit radius (server-reported distance).
            // Items beyond this are not eligible for the feed — no point showing them
            // just to immediately mark them "WALKED AWAY".
            let eligible = allItems.filter { $0.distanceMeters <= exitRadiusMeters }

            FeedDebugLogger.log(.feed, "refreshFromLocation — GOT \(allItems.count) items, \(eligible.count) eligible (had \(items.count))", detail: "hadContent=\(hadContent)")
            for (i, item) in allItems.enumerated() {
                let inFeed = eligible.contains(where: { $0.id == item.id })
                FeedDebugLogger.log(.feed, "  [\(i)] \(item.contentType.rawValue) id=\(item.id.uuidString.prefix(8))… dist=\(String(format: "%.1f", item.distanceMeters))m @\(item.username)\(inFeed ? "" : " [EXCLUDED]")")
            }

            if eligible.isEmpty {
                // All server items are beyond exit radius
                if hadContent {
                    FeedDebugLogger.log(.feed, "refreshFromLocation — no eligible items, clearing feed")
                    items = []
                    mediaPreloader.cancelAll()
                    cancelAllExitTimers()
                    itemRangeStates.removeAll()
                    exitConfirmationCounts.removeAll()
                    feedState = .empty
                } else {
                    feedState = .empty
                }
            } else {
                // Replace feed with eligible items only — all start as inRange
                mediaPreloader.setItems(eligible)
                items = eligible
                initializeRangeStates(for: eligible)

                if showEndOfFeedAlert { showEndOfFeedAlert = false }

                if hadContent {
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

        // Mark initial refresh as completed (prevents double-refresh at startup)
        hasCompletedInitialRefresh = true
    }

    /// Initialize range states for newly fetched items.
    /// All items in the feed are pre-filtered to within exit radius, so they
    /// all start as inRange. Previous states are NOT preserved — a server refresh
    /// is a "truth reset". This prevents stale outOfRange/gracePeriod states from
    /// persisting after the server confirms an item is still nearby.
    private func initializeRangeStates(for newItems: [ContentItem]) {
        // Cancel all in-flight exit timers from the previous state
        cancelAllExitTimers()
        exitConfirmationCounts.removeAll()

        // All items start fresh as inRange
        var newStates: [UUID: RangeState] = [:]
        for item in newItems {
            newStates[item.id] = .inRange
        }
        itemRangeStates = newStates
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

            let radius = queryRadius()
            FeedDebugLogger.log(.feed, "smartRefresh — fetching at lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) r=\(radius)m")

            do {
                let allItems = try await feedDataService.fetchNearbyContent(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    radius: radius
                )

                // Filter to eligible items (within exit radius by server-reported distance)
                let eligible = allItems.filter { $0.distanceMeters <= exitRadiusMeters }
                let existingIds = items.map(\.id)
                let eligibleIds = eligible.map(\.id)

                if eligible.isEmpty {
                    FeedDebugLogger.log(.feed, "smartRefresh — EMPTY (all \(allItems.count) items beyond exit radius)")
                    items = []
                    mediaPreloader.cancelAll()
                    cancelAllExitTimers()
                    itemRangeStates.removeAll()
                    exitConfirmationCounts.removeAll()
                    feedState = .empty
                } else if existingIds == eligibleIds {
                    FeedDebugLogger.log(.feed, "smartRefresh — SAME \(eligible.count) eligible items (URLs + range states refreshed)")
                    mediaPreloader.setItems(eligible)
                    items = eligible
                    // Reset range states even for same items — server confirmed they're nearby
                    initializeRangeStates(for: eligible)
                } else {
                    FeedDebugLogger.log(.feed, "smartRefresh — DIFFERENT content: \(items.count)→\(eligible.count) eligible (of \(allItems.count) total)")
                    for (i, item) in eligible.enumerated() {
                        FeedDebugLogger.log(.feed, "  [\(i)] \(item.contentType.rawValue) id=\(item.id.uuidString.prefix(8))… dist=\(String(format: "%.1f", item.distanceMeters))m")
                    }

                    if showEndOfFeedAlert { showEndOfFeedAlert = false }
                    let currentItemId = currentIndex < items.count ? items[currentIndex].id : nil

                    mediaPreloader.setItems(eligible)
                    items = eligible
                    initializeRangeStates(for: eligible)

                    // Try to keep the user on the same item
                    if let cid = currentItemId,
                       let newIdx = eligible.firstIndex(where: { $0.id == cid }) {
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

                feedDataService.items = eligible
                feedDataService.error = nil
            } catch {
                FeedDebugLogger.log(.feed, "smartRefresh — NETWORK ERROR: \(error.localizedDescription)")
                if items.isEmpty {
                    feedState = .error("NO SIGNAL. CONTENT IS PATIENT. Check your connection and try again.")
                }
            }
        }
    }

    // MARK: - Auto-Advance Timer

    func startAutoAdvance() {
        guard feedState == .content, !items.isEmpty else {
            FeedDebugLogger.log(.feed, "startAutoAdvance — SKIPPED (state=\(feedState), items=\(items.count))")
            return
        }

        stopAutoAdvance()
        progress = 0.0
        FeedDebugLogger.log(.feed, "⏱ startAutoAdvance — 6s timer started at index \(currentIndex)/\(items.count - 1)")

        progressTimer = Timer.scheduledTimer(withTimeInterval: progressInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused, !self.isTimerPaused else { return }
                self.progress += self.progressInterval / self.autoAdvanceDuration
                if self.progress >= 1.0 {
                    self.progress = 1.0
                    // Stop the 60fps progress timer — it's done its job.
                    // Either advance succeeds (and startAutoAdvance restarts for next item),
                    // or it's blocked and we retry at 0.5s instead of 60fps.
                    self.progressTimer?.invalidate()
                    self.progressTimer = nil
                    self.attemptAutoAdvance()
                }
            }
        }
    }

    /// Attempt to advance. If blocked, retry every 0.5s (not 60fps).
    private func attemptAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil

        if !advanceToNext() {
            // Blocked — retry periodically
            autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isPaused, !self.isTimerPaused else { return }
                    if self.advanceToNext() {
                        self.autoAdvanceTimer?.invalidate()
                        self.autoAdvanceTimer = nil
                    }
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

    /// Advance to the next eligible (inRange + ready) item.
    /// Returns true if advance succeeded, false if blocked.
    @discardableResult
    func advanceToNext() -> Bool {
        guard !items.isEmpty else {
            stopAutoAdvance()
            return false
        }

        // Track view of current item before advancing
        if let item = currentItem {
            AnalyticsService.shared.track(.contentViewed, metadata: [
                "content_id": item.id.uuidString,
                "content_type": item.contentType.rawValue,
            ])
        }

        // Find next eligible item — skip gracePeriod items (they're about to be removed).
        // outOfRange items have already been removed from the feed.
        var nextIndex = currentIndex + 1
        while nextIndex < items.count {
            let nextId = items[nextIndex].id
            let nextRange = itemRangeStates[nextId] ?? .inRange
            if nextRange == .inRange { break }
            nextIndex += 1
        }

        guard nextIndex < items.count else {
            FeedDebugLogger.log(.feed, "▶ advanceToNext — END at index \(currentIndex)/\(items.count - 1)")
            stopAutoAdvance()
            progress = 0.0
            showEndOfFeedAlert = true
            return false
        }

        // Readiness gate: don't advance onto an unprepared item.
        guard mediaPreloader.isReady(nextIndex) else {
            // Not ready — will retry (caller handles retry timer)
            return false
        }

        FeedDebugLogger.log(.feed, "▶ advanceToNext — \(currentIndex)→\(nextIndex) of \(items.count)")

        stopAutoAdvance()
        currentIndex = nextIndex
        progress = 0.0
        return true
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

    func onPagerIndexChanged(_ index: Int) {
        guard index != currentIndex else { return }
        FeedDebugLogger.log(.feed, "onPagerIndexChanged — \(currentIndex)→\(index)")
        currentIndex = index
        progress = 0.0

        if showEndOfFeedAlert {
            FeedDebugLogger.log(.feed, "onPagerIndexChanged — clearing endOfFeedAlert")
            showEndOfFeedAlert = false
        }
    }

    func onPagerDragBegan() {
        FeedDebugLogger.log(.feed, "onPagerDragBegan — user started swiping, stopping timers")
        stopAutoAdvance()
    }

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
        guard !isTimerPaused else {
            FeedDebugLogger.log(.feed, "onPagerScrollSettled — SKIPPED (timer paused by modal)")
            return
        }
        FeedDebugLogger.log(.feed, "onPagerScrollSettled — restarting auto-advance at index \(currentIndex)")
        startAutoAdvance()
    }

    func dismissEndOfFeedAlert() {
        FeedDebugLogger.log(.feed, "dismissEndOfFeedAlert — user dismissed without refresh")
        showEndOfFeedAlert = false
        isTimerPaused = false
        startAutoAdvance()
    }

    func refreshFeedFromAlert() {
        FeedDebugLogger.log(.feed, "refreshFeedFromAlert — user tapped REFRESH on endOfFeed alert")
        showEndOfFeedAlert = false
        isTimerPaused = false
        stopAutoAdvance()
        progress = 0.0

        isRefreshing = true
        currentIndex = 0

        Task { @MainActor in
            defer { isRefreshing = false }

            var location = locationService.currentLocation
            if location == nil {
                location = await locationService.fetchCurrentLocation()
            }

            guard let location else {
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

    @MainActor
    private func performRefreshFetch(latitude: Double, longitude: Double) async {
        let radius = queryRadius()

        do {
            let allItems = try await feedDataService.fetchNearbyContent(
                latitude: latitude,
                longitude: longitude,
                radius: radius
            )

            // Filter to eligible items
            let eligible = allItems.filter { $0.distanceMeters <= exitRadiusMeters }

            if eligible.isEmpty {
                // User explicitly triggered this refresh — accept the empty result
                // unless accuracy is extremely poor (>50m)
                let accuracy = locationService.currentLocation?.horizontalAccuracy ?? 0
                if !items.isEmpty && accuracy > 50 {
                    FeedDebugLogger.log(.feed, "performRefreshFetch — no eligible items with poor accuracy (\(String(format: "%.0f", accuracy))m), keeping existing \(items.count) items")
                    currentIndex = 0
                    feedState = .content
                    mediaPreloader.updateBuffer(around: 0)
                    startAutoAdvance()
                } else {
                    FeedDebugLogger.log(.feed, "performRefreshFetch — no eligible items, clearing feed")
                    items = []
                    mediaPreloader.cancelAll()
                    cancelAllExitTimers()
                    itemRangeStates.removeAll()
                    exitConfirmationCounts.removeAll()
                    feedState = .empty
                }
            } else {
                FeedDebugLogger.log(.feed, "performRefreshFetch — \(eligible.count) eligible items (of \(allItems.count) total)")
                mediaPreloader.setItems(eligible)
                items = eligible
                initializeRangeStates(for: eligible)
                currentIndex = 0
                feedState = .content
                mediaPreloader.updateBuffer(around: 0)
                startAutoAdvance()

                feedDataService.items = eligible
                feedDataService.error = nil
            }
        } catch {
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
            radius: queryRadius()
        )
        if feedDataService.items.count > items.count {
            let eligible = feedDataService.items.filter { $0.distanceMeters <= exitRadiusMeters }
            guard eligible.count > items.count else { return }
            mediaPreloader.setItems(eligible)
            items = eligible
            initializeRangeStates(for: eligible)
            mediaPreloader.updateBuffer(around: currentIndex)
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
}
