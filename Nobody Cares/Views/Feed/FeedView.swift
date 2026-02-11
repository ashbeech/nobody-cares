//
//  FeedView.swift
//  Nobody Cares
//
//  The feed tab — full-screen, location-gated content display.
//
//  Interactions (per spec Section 9):
//  - Vertical swipe up: next content
//  - Vertical swipe down: previous content
//  - Press and hold: pause auto-advance
//  - Tap: toggle mute (video only)
//  - 6-second auto-advance with yellow progress bar in tab bar
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
                    EmptyFeedView(onMakeContent: onMakeContent)

                case .content:
                    contentView

                case .endOfFeed:
                    EndOfFeedView(
                        onMakeContent: onMakeContent,
                        onRefresh: { viewModel.refresh() }
                    )

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
        case .empty, .endOfFeed, .error, .loading:
            NCColor.background
        }
    }

    // MARK: - Content View

    private var contentView: some View {
        ZStack {
            if let item = viewModel.currentItem {
                ContentCardView(
                    item: item,
                    isMuted: viewModel.isMuted,
                    isPaused: viewModel.isPaused,
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
                .transition(.opacity)
            }
        }
        .gesture(swipeGesture)
        .simultaneousGesture(longPressGesture)
        .animation(.linear(duration: 0.15), value: viewModel.currentIndex)
    }

    // MARK: - Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50, coordinateSpace: .local)
            .onEnded { value in
                let verticalDistance = value.translation.height

                if verticalDistance < -50 {
                    viewModel.advanceToNext()
                    if viewModel.feedState == .content {
                        viewModel.startAutoAdvance()
                    }
                } else if verticalDistance > 50 {
                    viewModel.goToPrevious()
                    viewModel.startAutoAdvance()
                }
            }
    }

    // MARK: - Long Press Gesture (pause)

    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .onChanged { _ in
                viewModel.setPaused(true)
            }
            .onEnded { _ in
                viewModel.setPaused(false)
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
        ZStack {
            NCColor.background.ignoresSafeArea()

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
}

#Preview("Feed - Loading") {
    FeedView()
        .environment(AppState())
}
