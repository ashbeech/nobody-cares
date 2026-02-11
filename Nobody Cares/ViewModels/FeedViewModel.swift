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
    var currentIndex: Int = 0
    var isMuted: Bool = true
    var isPaused: Bool = false
    var progress: Double = 0.0

    // MARK: - Services

    let locationService = LocationService()
    let feedDataService = FeedDataService()

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
        feedState = .loading

        // Set up location callbacks
        locationService.onSignificantMovement = { [weak self] in
            Task { @MainActor in
                await self?.refreshFromLocation()
            }
        }

        locationService.onBecameStationary = { [weak self] in
            Task { @MainActor in
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
                await self?.refreshFromLocation()
            }
        }

        // Start location monitoring
        locationService.startMonitoring()

        // Initial load with a brief delay for first location fix
        Task {
            // Wait briefly for first GPS fix
            try? await Task.sleep(for: .seconds(1))
            await refreshFromLocation()
        }
    }

    func stopFeed() {
        locationService.stopMonitoring()
        stopAutoAdvance()
        Task { await feedDataService.unsubscribeFromCell() }
    }

    // MARK: - Content Fetching

    @MainActor
    private func refreshFromLocation() async {
        guard let location = locationService.currentLocation else {
            // Try to get a location
            let fetched = await locationService.fetchCurrentLocation()
            if fetched == nil {
                AnalyticsService.shared.track(.locationUnavailable, metadata: ["source": "feed"])
            feedState = .error("NO SIGNAL. CONTENT IS PATIENT. Move to an area with GPS signal.")
            }
            return
        }

        let radius = locationService.effectiveRadius

        await feedDataService.refresh(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radius: radius
        )

        if let error = feedDataService.error {
            AnalyticsService.shared.track(.networkError, metadata: ["source": "feed", "error": error])
            feedState = .error("NO SIGNAL. CONTENT IS PATIENT. Check your connection and try again.")
        } else if feedDataService.items.isEmpty {
            items = []
            feedState = .empty
        } else {
            items = feedDataService.items
            currentIndex = 0
            progress = 0.0
            feedState = .content
            startAutoAdvance()
        }
    }

    // MARK: - Auto-Advance Timer

    func startAutoAdvance() {
        stopAutoAdvance()
        progress = 0.0

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
        progressTimer?.invalidate()
        progressTimer = nil
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    // MARK: - Navigation

    func advanceToNext() {
        // Track view of current item before advancing
        if let item = currentItem {
            AnalyticsService.shared.track(.contentViewed, metadata: [
                "content_id": item.id.uuidString,
                "content_type": item.contentType.rawValue,
            ])
        }

        guard currentIndex < items.count - 1 else {
            stopAutoAdvance()
            feedState = .endOfFeed

            // Try to load more
            Task {
                guard let location = locationService.currentLocation else { return }
                await feedDataService.loadMore(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    radius: locationService.effectiveRadius
                )
                if feedDataService.items.count > items.count {
                    await MainActor.run {
                        items = feedDataService.items
                        feedState = .content
                        startAutoAdvance()
                    }
                }
            }
            return
        }

        currentIndex += 1
        progress = 0.0
    }

    func goToPrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        progress = 0.0
    }

    func refresh() {
        currentIndex = 0
        progress = 0.0
        feedState = .loading
        Task { await refreshFromLocation() }
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func goToFirst() {
        guard !items.isEmpty else { return }
        currentIndex = 0
        progress = 0.0
        feedState = .content
        startAutoAdvance()
    }

    func goToLast() {
        guard !items.isEmpty else { return }
        currentIndex = items.count - 1
        progress = 0.0
        feedState = .content
        startAutoAdvance()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    // MARK: - Realtime Mode

    @MainActor
    private func switchToRealtimeMode() async {
        guard let location = locationService.currentLocation else { return }

        let cellId = S2CellCalculator.cellId(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )

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
