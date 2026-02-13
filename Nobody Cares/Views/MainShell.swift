//
//  MainShell.swift
//  Nobody Cares
//
//  Root navigation shell — top bar, content area, progress bar, tab bar.
//  Hides chrome when camera is active.
//

import SwiftUI

struct MainShell: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        ZStack {
            VStack(spacing: 0) {
                // Top bar (hidden during camera)
                if !appState.isCameraActive {
                    TopBar {
                        appState.showSettings = true
                    }
                }

                // Content area
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom tab bar (hidden during camera)
                if !appState.isCameraActive {
                    BottomTabBar(
                        selectedTab: $state.selectedTab,
                        progress: appState.feedProgress
                    )
                }
            }

            // "CONTENT ARCHIVED" banner
            if appState.showArchivedBanner {
                archivedBanner
            }

            // Settings
            if state.showSettings {
                SettingsView()
                    .zIndex(100)
                    .onAppear {
                        AnalyticsService.shared.track(.settingsOpened)
                    }
            }
        }
        // Deep link dialog
        .overlay {
            if appState.showDeepLinkDialog, let result = appState.deepLinkResult {
                deepLinkDialog(for: result)
                    .transition(.move(edge: .bottom))
                    .zIndex(200)
            }
        }
        .animation(.linear(duration: 0.2), value: appState.showDeepLinkDialog)
    }

    // MARK: - Deep Link Dialog

    private func deepLinkDialog(for result: DeepLinkResult) -> RetroDialog {
        switch result {
        case .accessDenied(let distance):
            RetroDialog(
                title: "ACCESS DENIED",
                icon: .lock,
                headline: "YOU ARE NOT CLOSE ENOUGH",
                body_text: "This content is geo-locked. You are \(Int(distance))m away. Move within 14m to view it. Or don't. Nobody cares.",
                primaryAction: .init(title: "DISMISS") {
                    appState.showDeepLinkDialog = false
                    appState.deepLinkResult = nil
                }
            )
        case .notFound:
            RetroDialog(
                title: "ERROR",
                icon: .caution,
                headline: "CONTENT NOT FOUND",
                body_text: "This content has been deleted or never existed. Both outcomes are equally unremarkable.",
                primaryAction: .init(title: "DISMISS") {
                    appState.showDeepLinkDialog = false
                    appState.deepLinkResult = nil
                }
            )
        case .error(let message):
            RetroDialog(
                title: "ERROR",
                icon: .caution,
                headline: "DEEP LINK FAILED",
                body_text: message,
                primaryAction: .init(title: "DISMISS") {
                    appState.showDeepLinkDialog = false
                    appState.deepLinkResult = nil
                }
            )
        case .content:
            RetroDialog(
                title: "CONTENT FOUND",
                icon: .eye,
                headline: "CONTENT AVAILABLE",
                body_text: "The linked content is within range. Switching to feed.",
                primaryAction: .init(title: "VIEW") {
                    appState.showDeepLinkDialog = false
                    appState.deepLinkResult = nil
                    appState.selectedTab = .feed
                }
            )
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch appState.selectedTab {
        case .feed:
            FeedView(onMakeContent: {
                appState.selectedTab = .create
            })

        case .create:
            CreateView()
        }
    }

    // MARK: - Archived Banner

    private var archivedBanner: some View {
        VStack {
            if !appState.isCameraActive {
                Spacer()
                    .frame(height: NCMetrics.topBarHeight)
            }

            HStack {
                Text("\u{2713} CONTENT ARCHIVED")
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.linear(duration: 0.15)) {
                    appState.showArchivedBanner = false
                }
            }
        }
    }
}

#Preview("Main Shell") {
    MainShell()
        .environment(AppState())
        .environment(AuthService())
        .environment(PermissionService())
        .environment(APIGuard())
}
