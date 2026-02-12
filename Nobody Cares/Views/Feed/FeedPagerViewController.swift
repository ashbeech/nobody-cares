//
//  FeedPagerViewController.swift
//  Nobody Cares
//
//  Vertically-paged UICollectionView that implements the TikTok-style pager spec:
//
//  • Full-screen cells (one item per page, no inter-item spacing).
//  • Finger-tracking: native UIScrollView 1:1 drag.
//  • Deterministic snap via scrollViewWillEndDragging (distance + velocity).
//  • Readiness gate: paging is blocked if the destination isn't preloaded.
//  • Adjacent prefetch via UICollectionViewDataSourcePrefetching.
//  • Buffer shift on page commit (scrollViewDidEndDecelerating / scrollViewDidEndDragging).
//  • 3-player AVPlayer pool managed by MediaPreloader.
//  • Pull-to-refresh via UIRefreshControl (smart — won't reload identical content).
//  • Hold-to-pause via UILongPressGestureRecognizer (simultaneous with scroll).
//

import UIKit
import SwiftUI

final class FeedPagerViewController: UIViewController {

    // MARK: - Data

    private(set) var items: [ContentItem] = []
    var mediaPreloader: MediaPreloader?

    // MARK: - State

    private(set) var currentIndex: Int = 0
    private var dragStartIndex: Int = 0
    var isMuted: Bool = true
    var isPaused: Bool = false
    var currentUserId: UUID?

    /// Per-item range state for proximity overlays. Keyed by content ID.
    var itemRangeStates: [UUID: RangeState] = [:]

    /// True while setContentOffset(animated:true) is in flight.
    private var isProgrammaticScroll = false
    private var isPauseActive = false
    /// Tracks bounds size to avoid redundant layout invalidation.
    private var lastLayoutSize: CGSize = .zero

    // MARK: - Callbacks

    var onIndexChanged: ((Int) -> Void)?
    var onDragBegan: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onPauseChanged: ((Bool) -> Void)?
    var onScrollSettled: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onReport: ((ContentItem) -> Void)?
    var onBlock: ((ContentItem) -> Void)?
    var onShare: ((ContentItem) -> Void)?

    // MARK: - UI

    private(set) var collectionView: UICollectionView!
    private let refreshControl = UIRefreshControl()

    // MARK: - Snap Constants

    private let distThreshold: CGFloat = 0.33   // fraction of page height
    private let velocityThreshold: CGFloat = 1.2 // pages / second

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCollectionView()
        setupRefreshControl()
        setupLongPressGesture()

        mediaPreloader?.onReadinessChanged = { [weak self] index, ready in
            self?.handleReadinessChanged(index: index, ready: ready)
        }

        // If items were set before the view loaded, apply them now
        if !items.isEmpty {
            collectionView.reloadData()
            mediaPreloader?.updateBuffer(around: currentIndex)
            // Only activate playback if current item is in range
            let currentId = currentIndex < items.count ? items[currentIndex].id : nil
            let rangeState = currentId.flatMap { itemRangeStates[$0] } ?? .inRange
            if rangeState == .inRange {
                mediaPreloader?.activatePlayback(at: currentIndex, isMuted: isMuted, isPaused: isPaused)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Only invalidate layout + re-snap when the view size actually changed
        // (rotation, split-view resize, safe-area shift).  Firing on every
        // layout pass was fighting programmatic scroll animations.
        let currentSize = collectionView.bounds.size
        guard currentSize != lastLayoutSize else { return }
        lastLayoutSize = currentSize

        collectionView.collectionViewLayout.invalidateLayout()

        // Re-align to the current page after a genuine size change,
        // but never during any active scroll (user drag, deceleration,
        // or programmatic animated scroll).
        if !items.isEmpty
            && !collectionView.isDragging
            && !collectionView.isDecelerating
            && !isProgrammaticScroll
        {
            let target = CGFloat(currentIndex) * currentSize.height
            if abs(collectionView.contentOffset.y - target) > 1 {
                collectionView.contentOffset.y = target
            }
        }
    }

    // MARK: - Setup

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self

        // Paging behaviour — we implement custom snap, so no system paging.
        collectionView.isPagingEnabled = false
        collectionView.bounces = true
        collectionView.alwaysBounceVertical = true
        collectionView.decelerationRate = .fast
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.allowsSelection = false

        collectionView.register(FeedContentCell.self, forCellWithReuseIdentifier: FeedContentCell.reuseId)

        view.addSubview(collectionView)
    }

    private func setupRefreshControl() {
        refreshControl.tintColor = .white
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl
    }

    private func setupLongPressGesture() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        collectionView.addGestureRecognizer(longPress)
    }

    // MARK: - Public API

    func updateItems(_ newItems: [ContentItem]) {
        let oldCount = items.count
        items = newItems
        FeedDebugLogger.log(.pager, "updateItems — \(oldCount)→\(newItems.count) items")

        // collectionView is set up in viewDidLoad — may not exist yet
        guard collectionView != nil else {
            FeedDebugLogger.log(.pager, "updateItems — collectionView not yet loaded, deferring")
            return
        }

        // reloadData() invalidates any in-flight animated setContentOffset.
        // scrollViewDidEndScrollingAnimation will never fire for the killed
        // animation, so clear the flag now to avoid permanently blocking
        // future scrolls via isScrollBusy.
        if isProgrammaticScroll {
            FeedDebugLogger.log(.pager, "updateItems — clearing stuck isProgrammaticScroll")
            isProgrammaticScroll = false
        }

        collectionView.reloadData()

        // Clamp current index
        if items.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(currentIndex, items.count - 1)
        }

        // Preserve scroll position after reload. Without this, removing an item
        // mid-feed can cause the pager to show the wrong page for one frame.
        let H = collectionView.bounds.height
        if !items.isEmpty, H > 0 {
            let expectedOffset = CGFloat(currentIndex) * H
            if abs(collectionView.contentOffset.y - expectedOffset) > 1 {
                collectionView.contentOffset = CGPoint(x: 0, y: expectedOffset)
            }
        }

        // If we just went from 0→N items, scroll to index 0 and start playback
        if oldCount == 0 && !items.isEmpty {
            FeedDebugLogger.log(.pager, "updateItems — 0→\(newItems.count): scrolling to index 0, activating playback")
            collectionView.contentOffset = .zero
            currentIndex = 0
            mediaPreloader?.updateBuffer(around: 0)
            // Only activate playback if first item is in range
            let firstId = items[0].id
            let rangeState = itemRangeStates[firstId] ?? .inRange
            if rangeState == .inRange {
                mediaPreloader?.activatePlayback(at: 0, isMuted: isMuted, isPaused: isPaused)
            }
        }
    }

    /// Programmatic scroll (auto-advance or ViewModel-driven).
    ///
    /// **Animated** scrolls (auto-advance ±1) respect the busy guards — we must
    /// not fight a user drag or ongoing deceleration.
    ///
    /// **Non-animated** scrolls (e.g. REFRESH → index 0) bypass ALL guards:
    /// they first kill any ongoing momentum, then snap the offset instantly.
    /// There is no animation to conflict with, so there is nothing to guard.
    func scrollToIndex(_ index: Int, animated: Bool) {
        guard index >= 0, index < items.count else {
            FeedDebugLogger.log(.pager, "scrollToIndex(\(index)) — BLOCKED (out of range, count=\(items.count))")
            return
        }
        let H = collectionView.bounds.height
        guard H > 0 else { return }

        if animated {
            // Animated: respect scroll-busy guards
            guard !collectionView.isDragging, !collectionView.isDecelerating else {
                FeedDebugLogger.log(.pager, "scrollToIndex(\(index)) — BLOCKED (scroll busy)")
                return
            }

            FeedDebugLogger.log(.pager, "scrollToIndex(\(index), animated=true) — programmatic scroll")
            isProgrammaticScroll = true
            collectionView.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * H), animated: true)
        } else {
            // Non-animated: force-stop any ongoing scroll, then snap instantly.
            // Setting contentOffset to the current value with animated:false is
            // a standard UIKit trick to kill deceleration momentum.
            FeedDebugLogger.log(.pager, "scrollToIndex(\(index), animated=false) — instant snap")
            collectionView.setContentOffset(collectionView.contentOffset, animated: false)
            isProgrammaticScroll = false
            collectionView.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * H), animated: false)
            handlePageCommit()
        }
    }

    func updateMuteState(_ muted: Bool) {
        isMuted = muted
        mediaPreloader?.updateMute(muted, currentIndex: currentIndex)
        refreshVisibleOverlays()

        // Also update adjacent cells (currentIndex ± 1). UICollectionView
        // pre-lays-out neighbors for smooth scrolling, but with full-screen
        // cells they're off-screen and excluded from indexPathsForVisibleItems.
        // Without this, the next/prev cell keeps its stale overlay until
        // handlePageCommit fires after the swipe settles — visible as a
        // split-second flash of the wrong mute icon.
        for offset in [-1, 1] {
            let idx = currentIndex + offset
            guard idx >= 0, idx < items.count else { continue }
            let indexPath = IndexPath(item: idx, section: 0)
            if let cell = collectionView.cellForItem(at: indexPath) as? FeedContentCell {
                configureCell(cell, at: idx)
            }
        }
    }

    func updatePauseState(_ paused: Bool) {
        isPaused = paused
        mediaPreloader?.updatePause(paused, currentIndex: currentIndex)
    }

    func endRefreshing() {
        refreshControl.endRefreshing()
    }

    /// Update range states and refresh all visible cells to reflect proximity changes.
    func updateRangeStates(_ states: [UUID: RangeState]) {
        let changed = states != itemRangeStates
        itemRangeStates = states
        if changed {
            refreshVisibleOverlays()

            // React to current item's range state change
            if currentIndex < items.count {
                let currentId = items[currentIndex].id
                let currentRange = states[currentId] ?? .inRange
                if currentRange != .inRange {
                    // gracePeriod or outOfRange — pause playback
                    // (outOfRange items will be removed from the feed shortly)
                    mediaPreloader?.pauseAll()
                } else if let preloader = mediaPreloader, preloader.isReady(currentIndex) {
                    // inRange and ready — resume playback
                    preloader.activatePlayback(at: currentIndex, isMuted: isMuted, isPaused: isPaused)
                }
            }
        }
    }

    /// True when any scroll is in-flight (user drag, deceleration, or programmatic animation).
    /// Used by FeedPagerView to avoid re-triggering scrollToIndex mid-animation.
    var isScrollBusy: Bool {
        collectionView.isDragging || collectionView.isDecelerating || isProgrammaticScroll
    }

    // MARK: - Actions

    @objc private func handleRefresh() {
        FeedDebugLogger.log(.pager, "handleRefresh — pull-to-refresh triggered")
        onRefresh?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            if !isPauseActive {
                FeedDebugLogger.log(.pager, "long-press BEGAN — pausing")
                isPauseActive = true
                onPauseChanged?(true)
            }
        case .ended, .cancelled, .failed:
            if isPauseActive {
                FeedDebugLogger.log(.pager, "long-press ENDED — resuming")
                isPauseActive = false
                onPauseChanged?(false)
            }
        default:
            break
        }
    }

    // MARK: - Page Commit (called once scroll settles)

    private func handlePageCommit() {
        let H = collectionView.bounds.height
        guard H > 0, !items.isEmpty else { return }

        let raw = Int(round(collectionView.contentOffset.y / H))
        let clamped = max(0, min(raw, items.count - 1))

        let pageDidChange = (clamped != currentIndex)
        if pageDidChange {
            FeedDebugLogger.log(.pager, "handlePageCommit — page changed \(currentIndex)→\(clamped)")
        } else {
            FeedDebugLogger.log(.pager, "handlePageCommit — settled on same page \(clamped)")
        }
        currentIndex = clamped

        // Always report the VC's actual settled index.
        // This resyncs the ViewModel if its index drifted (e.g. a scroll
        // was interrupted). The VM's guard prevents redundant state changes.
        onIndexChanged?(clamped)

        // Only shift buffer + activate playback when the page genuinely changed.
        // Calling activatePlayback on every settle (including snap-back to same
        // page) was causing unnecessary pause/play cycles that glitched video.
        if pageDidChange {
            mediaPreloader?.updateBuffer(around: currentIndex)

            // Playback gating: only autoplay items that are inRange
            let currentItemId = clamped < items.count ? items[clamped].id : nil
            let rangeState = currentItemId.flatMap { itemRangeStates[$0] } ?? .inRange
            if rangeState == .inRange {
                mediaPreloader?.activatePlayback(at: currentIndex, isMuted: isMuted, isPaused: isPaused)
            } else {
                FeedDebugLogger.log(.pager, "handlePageCommit — index \(clamped) is \(rangeState), skipping playback")
            }

            refreshVisibleOverlays()
        }

        // Always notify that scrolling settled — ViewModel restarts auto-advance
        onScrollSettled?()
    }

    // MARK: - Readiness Callback (from MediaPreloader)

    private func handleReadinessChanged(index: Int, ready: Bool) {
        guard ready else { return }
        FeedDebugLogger.log(.pager, "readinessChanged — index \(index) now READY (current=\(currentIndex))")
        let indexPath = IndexPath(item: index, section: 0)
        if let cell = collectionView.cellForItem(at: indexPath) as? FeedContentCell {
            configureCell(cell, at: index)

            // If this is the current cell and it's a video, start playback (if in range)
            if index == currentIndex {
                let itemId = index < items.count ? items[index].id : nil
                let rangeState = itemId.flatMap { itemRangeStates[$0] } ?? .inRange
                if rangeState == .inRange {
                    FeedDebugLogger.log(.pager, "readinessChanged — hot-swapping playback for current index \(index)")
                    mediaPreloader?.activatePlayback(at: index, isMuted: isMuted, isPaused: isPaused)
                } else {
                    FeedDebugLogger.log(.pager, "readinessChanged — index \(index) is \(rangeState), skipping playback")
                }
            }
        }
    }

    // MARK: - Cell Configuration

    private func configureCell(_ cell: FeedContentCell, at index: Int) {
        guard index < items.count else { return }
        let item = items[index]

        let player = mediaPreloader?.player(for: index)
        let image = mediaPreloader?.image(for: index)
        let isCurrentItem = (index == currentIndex)
        let ready = mediaPreloader?.isReady(index) ?? false
        let rangeState = itemRangeStates[item.id] ?? .inRange

        cell.configure(
            contentType: item.contentType,
            player: player,
            preloadedImage: image,
            isMuted: isMuted,
            isPlaying: isCurrentItem && !isPaused && item.contentType == .video && rangeState != .outOfRange,
            isReady: ready,
            rangeState: rangeState
        )

        let overlay = ContentOverlayView(
            item: item,
            isMuted: isMuted,
            currentUserId: currentUserId,
            onToggleMute: { [weak self] in self?.onToggleMute?() },
            onReport: { [weak self] in self?.onReport?(item) },
            onBlock: { [weak self] in self?.onBlock?(item) },
            onShare: { [weak self] in self?.onShare?(item) }
        )
        cell.configureOverlay(overlay, parent: self)
    }

    private func refreshVisibleOverlays() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: indexPath) as? FeedContentCell {
                configureCell(cell, at: indexPath.item)
            }
        }
    }
}

// MARK: - UICollectionViewDataSource

extension FeedPagerViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FeedContentCell.reuseId, for: indexPath) as! FeedContentCell
        configureCell(cell, at: indexPath.item)
        return cell
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension FeedPagerViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }
}

// MARK: - UICollectionViewDataSourcePrefetching

extension FeedPagerViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            mediaPreloader?.prepare(index: indexPath.item)
        }
        // Belt-and-suspenders: also ensure ±1 neighbors are being prepared
        mediaPreloader?.updateBuffer(around: currentIndex)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            let index = indexPath.item
            // Only cancel if it's outside the ±2 buffer window
            if abs(index - currentIndex) > 2 {
                mediaPreloader?.cancel(index: index)
            }
        }
    }
}

// MARK: - UIScrollViewDelegate (snap logic + page commit)

extension FeedPagerViewController {

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        let H = collectionView.bounds.height
        guard H > 0 else { return }
        dragStartIndex = Int(round(scrollView.contentOffset.y / H))
        FeedDebugLogger.log(.pager, "👆 scrollViewWillBeginDragging — dragStartIndex=\(dragStartIndex)")
        onDragBegan?()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let H = collectionView.bounds.height
        guard H > 0, !items.isEmpty else { return }

        // Don't interfere with an active refresh control
        if refreshControl.isRefreshing {
            FeedDebugLogger.log(.pager, "scrollViewWillEndDragging — refresh active, not snapping")
            return
        }

        // Overscroll above top → snap to page 0
        if scrollView.contentOffset.y < 0 {
            FeedDebugLogger.log(.pager, "scrollViewWillEndDragging — overscroll above top, snap to 0")
            targetContentOffset.pointee.y = 0
            return
        }

        let lastIndex = items.count - 1

        // --- Deterministic snap decision ---

        // Drag distance in fractional pages (positive = toward higher index / next)
        let dragDistance = (scrollView.contentOffset.y - CGFloat(dragStartIndex) * H) / H

        // Release velocity in pages-per-second
        let vPagesPerSec = velocity.y / H

        var targetIndex = dragStartIndex

        if abs(dragDistance) >= distThreshold {
            targetIndex = dragDistance > 0 ? dragStartIndex + 1 : dragStartIndex - 1
        } else if abs(vPagesPerSec) >= velocityThreshold {
            targetIndex = velocity.y > 0 ? dragStartIndex + 1 : dragStartIndex - 1
        }
        // else → snap back to dragStartIndex

        // Clamp to valid range
        targetIndex = max(0, min(targetIndex, lastIndex))

        FeedDebugLogger.log(.pager, "👆 SNAP DECISION — dragStart=\(dragStartIndex) target=\(targetIndex)",
                            detail: "dragDist=\(String(format: "%.2f", dragDistance)) vel=\(String(format: "%.2f", vPagesPerSec)) distThresh=\(distThreshold) velThresh=\(velocityThreshold)")

        // No readiness gate on user swipes — swiping must always work.
        // If the destination isn't fully preloaded yet the cell will show
        // a poster frame or placeholder and hot-swap once ready.

        targetContentOffset.pointee.y = CGFloat(targetIndex) * H
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        FeedDebugLogger.log(.pager, "scrollViewDidEndDragging — willDecelerate=\(decelerate)")
        if !decelerate {
            handlePageCommit()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        FeedDebugLogger.log(.pager, "scrollViewDidEndDecelerating")
        handlePageCommit()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        FeedDebugLogger.log(.pager, "scrollViewDidEndScrollingAnimation (programmatic)")
        isProgrammaticScroll = false
        handlePageCommit()
    }
}

// MARK: - UIGestureRecognizerDelegate

extension FeedPagerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow long-press (hold-to-pause) to coexist with scroll
        gestureRecognizer is UILongPressGestureRecognizer
    }
}
