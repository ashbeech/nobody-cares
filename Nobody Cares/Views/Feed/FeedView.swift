//
//  FeedView.swift
//  Nobody Cares
//
//  The feed tab — full-screen, location-gated content display.
//
//  Interactions (per spec Section 9):
//  - Vertical swipe up/down: UICollectionView pager with deterministic snap
//  - Press and hold: pause all playback and auto-advance
//  - Tap: toggle mute (video only)
//  - 6-second auto-advance with yellow progress bar in tab bar
//  - Pull-to-refresh (smart — won't reload identical content)
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
                    EmptyFeedView(
                        isRefreshing: viewModel.isEmptyRefreshing,
                        onMakeContent: onMakeContent,
                        onRefresh: { viewModel.refreshFromEmptyState() }
                    )

                case .content:
                    FeedPagerView(
                        viewModel: viewModel,
                        appState: appState,
                        onReport: { item in
                            reportContentId = item.id
                            showReport = true
                        },
                        onBlock: { item in
                            blockItem = item
                            showBlockConfirm = true
                        },
                        onShare: { item in
                            shareContent(item)
                        }
                    )
                    .ignoresSafeArea()

                case .endOfFeed:
                    // Hard-stop at last item — this state should not be reached
                    // from the pager flow, but kept for safety.
                    EmptyView()

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

            // End-of-feed alert — overlays on top of still-playing content
            if viewModel.showEndOfFeedAlert {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.dismissEndOfFeedAlert()
                    }

                RetroWindow(
                    title: "ALERT",
                    icon: .caution,
                    showCloseBox: true,
                    onClose: { viewModel.dismissEndOfFeedAlert() }
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("NO MORE LOCAL CONTENT")
                            .font(NCFont.display(16))
                            .foregroundColor(NCColor.ink)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        Text("You've reached the end. Make something or move somewhere new.")
                            .font(NCFont.dialogBody)
                            .foregroundColor(NCColor.ink)
                            .lineSpacing(4)

                        HStack(spacing: 12) {
                            Spacer()
                            RetroButton(
                                title: "REFRESH",
                                variant: .secondary,
                                trailingIcon: .recycle
                            ) {
                                viewModel.refreshFeedFromAlert()
                            }
                            RetroButton(
                                title: "MAKE CONTENT",
                                variant: .primary
                            ) {
                                viewModel.dismissEndOfFeedAlert()
                                onMakeContent()
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(NCMetrics.dialogPadding)
                }
                .padding(.horizontal, 32)
                .transition(.move(edge: .bottom))
            }

            // Blocked banner
            if showBlockedBanner {
                blockedBanner
            }

        }
        .animation(.linear(duration: 0.2), value: showReport)
        .animation(.linear(duration: 0.2), value: viewModel.showEndOfFeedAlert)
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
        .onChange(of: viewModel.feedState) { _, newState in
            // No drag state to reset — pager handles its own scroll state
        }
        // Case B: Report — pause BOTH timer and video
        .onChange(of: showReport) { _, isShowing in
            viewModel.setPaused(isShowing)
        }
        // Case B: Block — pause BOTH timer and video
        .onChange(of: showBlockConfirm) { _, isShowing in
            viewModel.setPaused(isShowing)
        }
        // Case A: End-of-feed alert — pause timer ONLY, video keeps playing
        .onChange(of: viewModel.showEndOfFeedAlert) { _, isShowing in
            viewModel.isTimerPaused = isShowing
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
                    viewModel.mediaPreloader.setItems(viewModel.items)
                    if viewModel.items.isEmpty {
                        viewModel.feedState = .empty
                    } else if viewModel.currentIndex >= viewModel.items.count {
                        viewModel.currentIndex = max(0, viewModel.items.count - 1)
                    }
                    viewModel.mediaPreloader.updateBuffer(around: viewModel.currentIndex)
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
