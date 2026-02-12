//
//  FeedPagerView.swift
//  Nobody Cares
//
//  UIViewControllerRepresentable bridge that connects FeedViewModel (SwiftUI)
//  to FeedPagerViewController (UIKit).  Syncs items, mute/pause state,
//  auto-advance index, and refresh completion.
//

import SwiftUI

struct FeedPagerView: UIViewControllerRepresentable {

    @Bindable var viewModel: FeedViewModel
    let appState: AppState
    var onReport: (ContentItem) -> Void
    var onBlock: (ContentItem) -> Void
    var onShare: (ContentItem) -> Void

    // MARK: - Make

    func makeUIViewController(context: Context) -> FeedPagerViewController {
        let vc = FeedPagerViewController()
        vc.mediaPreloader = viewModel.mediaPreloader
        context.coordinator.viewController = vc

        // --- Wire callbacks ---

        vc.onIndexChanged = { [weak viewModel] index in
            guard let viewModel else { return }
            viewModel.onPagerIndexChanged(index)
        }

        vc.onDragBegan = { [weak viewModel] in
            viewModel?.onPagerDragBegan()
        }

        vc.onScrollSettled = { [weak viewModel] in
            viewModel?.onPagerScrollSettled()
        }

        vc.onToggleMute = { [weak viewModel] in
            viewModel?.toggleMute()
        }

        vc.onPauseChanged = { [weak viewModel] paused in
            viewModel?.setPaused(paused)
        }

        vc.onRefresh = { [weak viewModel] in
            viewModel?.smartRefresh()
        }

        vc.onReport = onReport
        vc.onBlock = onBlock
        vc.onShare = onShare

        // Initial data push
        vc.isMuted = viewModel.isMuted
        vc.isPaused = viewModel.isPaused
        vc.currentUserId = appState.userId
        viewModel.mediaPreloader.setItems(viewModel.items)
        vc.updateItems(viewModel.items)

        return vc
    }

    // MARK: - Update

    func updateUIViewController(_ vc: FeedPagerViewController, context: Context) {
        let coord = context.coordinator

        // Items — compare by ID list to avoid unnecessary reloads
        let newIds = viewModel.items.map(\.id)
        if coord.lastItemIds != newIds {
            coord.lastItemIds = newIds
            viewModel.mediaPreloader.setItems(viewModel.items)
            vc.updateItems(viewModel.items)
        }

        // Range states — push proximity overlay changes to pager
        if coord.lastRangeStates != viewModel.itemRangeStates {
            coord.lastRangeStates = viewModel.itemRangeStates
            vc.updateRangeStates(viewModel.itemRangeStates)
        }

        // Mute
        if coord.lastMuted != viewModel.isMuted {
            coord.lastMuted = viewModel.isMuted
            vc.updateMuteState(viewModel.isMuted)
        }

        // Pause
        if coord.lastPaused != viewModel.isPaused {
            coord.lastPaused = viewModel.isPaused
            vc.updatePauseState(viewModel.isPaused)
        }

        // User ID
        vc.currentUserId = appState.userId

        // Programmatic index change (auto-advance or refresh).
        //
        // • Single-page hop (±1, e.g. auto-advance): animate smoothly.
        //   Respect isScrollBusy to avoid fighting a user drag or deceleration.
        //
        // • Multi-page jump (e.g. REFRESH from last item → 0): snap instantly.
        //   Bypass isScrollBusy — scrollToIndex(animated:false) will force-stop
        //   any ongoing momentum before snapping.
        if vc.currentIndex != viewModel.currentIndex {
            let distance = abs(vc.currentIndex - viewModel.currentIndex)
            if distance > 1 {
                // Multi-page: instant snap, bypass busy guard
                vc.scrollToIndex(viewModel.currentIndex, animated: false)
            } else if !vc.isScrollBusy {
                // Single-page: smooth animation, respect busy guard
                vc.scrollToIndex(viewModel.currentIndex, animated: true)
            }
        }

        // Refresh completion
        if !viewModel.isRefreshing && coord.wasRefreshing {
            vc.endRefreshing()
        }
        coord.wasRefreshing = viewModel.isRefreshing
    }

    // MARK: - Coordinator

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var viewController: FeedPagerViewController?

        // Cached state to avoid redundant updates in updateUIViewController
        var lastItemIds: [UUID] = []
        var lastMuted: Bool = true
        var lastPaused: Bool = false
        var wasRefreshing: Bool = false
        var lastRangeStates: [UUID: RangeState] = [:]
    }
}
