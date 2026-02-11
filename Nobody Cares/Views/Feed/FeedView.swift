//
//  FeedView.swift
//  Nobody Cares
//
//  The feed tab — full-screen, location-gated content display.
//
//  Interactions (per spec Section 9):
//  - Vertical swipe up/down: navigate content with TikTok-style finger tracking
//  - Press and hold: pause all playback and auto-advance
//  - Tap: toggle mute (video only)
//  - 6-second auto-advance with yellow progress bar in tab bar
//  - Pull-to-refresh at first item
//  - Report, block, and share actions
//

import SwiftUI

struct FeedView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = FeedViewModel()
    @State private var showReport = false
    @State private var reportContentId: UUID?
    @State private var showBlockConfirm = false
    @State private var blockItem: ContentItem?
    @State private var showBlockedBanner = false

    // TikTok-style scroll state
    @State private var dragOffset: CGFloat = 0
    @State private var isTransitioning = false

    // Hold-to-pause state (auto-resets when gesture ends)
    @GestureState private var isLongPressing = false

    // EndOfFeed drag state
    @State private var endOfFeedDragOffset: CGFloat = 0

    // Constants
    private let pullThreshold: CGFloat = 100
    private let swipeThreshold: CGFloat = 50
    private let animationDuration: Double = 0.3

    var onMakeContent: () -> Void = {}

    var body: some View {
        ZStack {
            // Dynamic background — extends edge to edge
            feedBackground
                .ignoresSafeArea()

            Group {
                switch viewModel.feedState {
                case .loading:
                    LoadingFeedView()

                case .empty:
                    EmptyFeedView(onMakeContent: onMakeContent)

                case .content:
                    contentView

                case .endOfFeed:
                    endOfFeedWithGesture

                case .error(let message):
                    errorView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Report modal overlay
            if showReport, let contentId = reportContentId {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .onTapGesture { showReport = false }

                ReportView(contentId: contentId) {
                    showReport = false
                    reportContentId = nil
                }
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom))
            }

            // Blocked banner
            if showBlockedBanner {
                blockedBanner
            }
        }
        .animation(.linear(duration: 0.2), value: showReport)
        .onAppear {
            viewModel.startFeed()
            AnalyticsService.shared.track(.feedOpened)
        }
        .onDisappear {
            viewModel.stopFeed()
        }
        .onChange(of: viewModel.progress) { _, newValue in
            appState.feedProgress = newValue
        }
        .onChange(of: viewModel.isPaused) { _, newValue in
            appState.isFeedPaused = newValue
        }
        .onChange(of: isLongPressing) { _, pressing in
            viewModel.setPaused(pressing)
        }
        .onChange(of: viewModel.feedState) { _, newState in
            if newState != .content {
                dragOffset = 0
                isTransitioning = false
            }
        }
        .retroDialog(isPresented: $showBlockConfirm) {
            RetroDialog(
                title: "BLOCK USER",
                icon: .block,
                headline: "BLOCK @\(blockItem?.username.uppercased() ?? "USER")?",
                body_text: "All content from this user will be permanently hidden from your feed. This cannot be undone. Not that anyone would want to.",
                primaryAction: .init(title: "BLOCK") {
                    if let userId = blockItem?.userId {
                        performBlock(userId: userId)
                    }
                },
                secondaryAction: .init(title: "CANCEL") {
                    showBlockConfirm = false
                    blockItem = nil
                }
            )
        }
    }

    // MARK: - Dynamic Background

    @ViewBuilder
    private var feedBackground: some View {
        switch viewModel.feedState {
        case .content:
            Color.black
        default:
            // Animated dither — persistent background for all non-media states
            DitherPatternView(
                style: .light,
                foreground: NCColor.dither,
                background: NCColor.background,
                animated: true
            )
        }
    }

    // MARK: - Content View (TikTok-style vertical scroll)

    private var contentView: some View {
        GeometryReader { geometry in
            let screenHeight = geometry.size.height

            ZStack {
                // Pull-to-refresh background and indicator (above first item)
                if viewModel.currentIndex == 0 && dragOffset > 0 {
                    pullToRefreshArea(in: geometry)
                }

                // Previous item peeking above
                if viewModel.currentIndex > 0 {
                    peekCard(for: viewModel.items[viewModel.currentIndex - 1], in: geometry)
                        .frame(width: geometry.size.width, height: screenHeight)
                        .offset(y: dragOffset - screenHeight)
                }

                // Current item
                if let item = viewModel.currentItem {
                    ContentCardView(
                        item: item,
                        isMuted: viewModel.isMuted,
                        isPaused: viewModel.isPaused,
                        currentUserId: appState.userId,
                        onToggleMute: { viewModel.toggleMute() },
                        onReport: {
                            reportContentId = item.id
                            showReport = true
                        },
                        onBlock: {
                            blockItem = item
                            showBlockConfirm = true
                        },
                        onShare: {
                            shareContent(item)
                        }
                    )
                    .id(item.id)
                    .frame(width: geometry.size.width, height: screenHeight)
                    .offset(y: dragOffset)
                }

                // Next item or EndOfFeed peeking below
                if viewModel.currentIndex < viewModel.items.count - 1 {
                    peekCard(for: viewModel.items[viewModel.currentIndex + 1], in: geometry)
                        .frame(width: geometry.size.width, height: screenHeight)
                        .offset(y: dragOffset + screenHeight)
                } else {
                    EndOfFeedView(
                        onMakeContent: onMakeContent,
                        onRefresh: { viewModel.refresh() }
                    )
                    .frame(width: geometry.size.width, height: screenHeight)
                    .offset(y: dragOffset + screenHeight)
                }
            }
        }
        .clipped()
        .gesture(swipeGesture)
        .simultaneousGesture(holdGesture)
    }

    // MARK: - Peek Card (lightweight preview for adjacent items)

    @ViewBuilder
    private func peekCard(for item: ContentItem, in geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black
            if item.contentType == .image, let url = item.signedURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                }
            }
        }
    }

    // MARK: - Pull-to-Refresh Area

    private func pullToRefreshArea(in geometry: GeometryProxy) -> some View {
        let screenHeight = geometry.size.height
        let progress = min(dragOffset / (pullThreshold * 0.5), 1.5)

        return ZStack {
            // Dither background for the revealed gap
            DitherPatternView(
                style: .light,
                foreground: NCColor.dither,
                background: NCColor.background,
                animated: true
            )

            // Hourglass indicator
            VStack(spacing: 8) {
                PixelIcon(type: .hourglass, size: 28, color: NCColor.ink)
                    .rotationEffect(.degrees(progress * 180))
                    .scaleEffect(0.5 + min(progress, 1.0) * 0.5)

                if progress >= 1.0 {
                    Text("RELEASE TO REFRESH")
                        .font(NCFont.caption)
                        .foregroundColor(NCColor.ink)
                        .tracking(0.3)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: geometry.size.width, height: max(1, dragOffset))
        .offset(y: -(screenHeight - dragOffset) / 2)
    }

    // MARK: - Swipe Gesture (TikTok-style finger tracking)

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard !isTransitioning else { return }
                let translation = value.translation.height

                if viewModel.currentIndex == 0 && translation > 0 {
                    // Pull-to-refresh: rubber band effect at top
                    dragOffset = translation * 0.5
                } else {
                    dragOffset = translation
                }
            }
            .onEnded { value in
                guard !isTransitioning else { return }
                let translation = value.translation.height
                let velocity = value.predictedEndTranslation.height - translation
                let screenHeight = UIScreen.main.bounds.height

                // Pull-to-refresh (at first item, pulled past threshold)
                if viewModel.currentIndex == 0 && translation > pullThreshold {
                    withAnimation(.easeOut(duration: animationDuration)) {
                        dragOffset = 0
                    }
                    viewModel.refresh()
                    return
                }

                let shouldAdvance = translation < -swipeThreshold || velocity < -300
                let shouldGoBack = translation > swipeThreshold || velocity > 300

                if shouldAdvance {
                    isTransitioning = true
                    withAnimation(.easeOut(duration: animationDuration)) {
                        dragOffset = -screenHeight
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                        viewModel.advanceToNext()
                        if viewModel.feedState == .content {
                            dragOffset = 0
                            viewModel.startAutoAdvance()
                        }
                        isTransitioning = false
                    }
                } else if shouldGoBack && viewModel.currentIndex > 0 {
                    isTransitioning = true
                    withAnimation(.easeOut(duration: animationDuration)) {
                        dragOffset = screenHeight
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                        viewModel.goToPrevious()
                        dragOffset = 0
                        viewModel.startAutoAdvance()
                        isTransitioning = false
                    }
                } else {
                    // Snap back — didn't meet threshold
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Hold Gesture (press and hold to pause everything)

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isLongPressing) { value, state, _ in
                switch value {
                case .second(true, _):
                    state = true
                default:
                    break
                }
            }
    }

    // MARK: - EndOfFeed with Gesture (swipe to return to content)

    private var endOfFeedWithGesture: some View {
        EndOfFeedView(
            onMakeContent: onMakeContent,
            onRefresh: { viewModel.refresh() }
        )
        .offset(y: endOfFeedDragOffset)
        .gesture(
            DragGesture(minimumDistance: 50)
                .onChanged { value in
                    endOfFeedDragOffset = value.translation.height
                }
                .onEnded { value in
                    let translation = value.translation.height
                    let screenHeight = UIScreen.main.bounds.height

                    if translation > 80 && !viewModel.items.isEmpty {
                        // Swipe down (top to bottom) → go to last content item
                        withAnimation(.easeOut(duration: animationDuration)) {
                            endOfFeedDragOffset = screenHeight
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                            endOfFeedDragOffset = 0
                            viewModel.goToLast()
                        }
                    } else if translation < -80 && !viewModel.items.isEmpty {
                        // Swipe up (bottom to top) → go to first content item
                        withAnimation(.easeOut(duration: animationDuration)) {
                            endOfFeedDragOffset = -screenHeight
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                            endOfFeedDragOffset = 0
                            viewModel.goToFirst()
                        }
                    } else {
                        // Snap back
                        withAnimation(.easeOut(duration: animationDuration)) {
                            endOfFeedDragOffset = 0
                        }
                    }
                }
        )
    }

    // MARK: - Block

    private func performBlock(userId: UUID) {
        Task {
            do {
                try await BlockService.shared.blockUser(blockedUserId: userId)
                await MainActor.run {
                    showBlockConfirm = false
                    blockItem = nil
                    // Remove blocked user's content from feed and advance
                    viewModel.items.removeAll { $0.userId == userId }
                    if viewModel.items.isEmpty {
                        viewModel.feedState = .empty
                    } else if viewModel.currentIndex >= viewModel.items.count {
                        viewModel.currentIndex = max(0, viewModel.items.count - 1)
                    }
                    showBlockedBanner = true
                }
            } catch {
                showBlockConfirm = false
                blockItem = nil
            }
        }
    }

    // MARK: - Share

    private func shareContent(_ item: ContentItem) {
        let shareURL = URL(string: "https://nobodycares.app/c/\(item.id.uuidString)")!
        let text = "Content on Nobody Cares — but only if you're there."

        let activityVC = UIActivityViewController(
            activityItems: [text, shareURL],
            applicationActivities: nil
        )

        // Present from the root view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }

        AnalyticsService.shared.track(.contentShared, metadata: [
            "content_id": item.id.uuidString,
        ])
    }

    // MARK: - Blocked Banner

    private var blockedBanner: some View {
        VStack {
            HStack {
                Text("\u{2717} USER BLOCKED")
                    .font(NCFont.body(14))
                    .foregroundColor(NCColor.accentYellow)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.horizontal, NCMetrics.contentPadding)
            .frame(height: 36)
            .background(NCColor.ink)

            Spacer()
        }
        .transition(.move(edge: .top))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.linear(duration: 0.15)) {
                    showBlockedBanner = false
                }
            }
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        // Background dither provided by feedBackground
        RetroDialog(
            title: "ERROR",
            icon: .caution,
            headline: "FEED UNAVAILABLE",
            body_text: message,
            primaryAction: .init(title: "RETRY") {
                viewModel.refresh()
            }
        )
        .padding(.horizontal, 32)
    }
}

#Preview("Feed - Loading") {
    FeedView()
        .environment(AppState())
}
