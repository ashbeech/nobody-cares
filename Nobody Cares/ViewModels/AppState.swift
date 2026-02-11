//
//  AppState.swift
//  Nobody Cares
//
//  Global application state — drives navigation, auth, and onboarding.
//

import SwiftUI

enum AppTab: String, CaseIterable {
    case feed
    case create
}

@Observable
final class AppState {
    // MARK: - Navigation
    var selectedTab: AppTab = .feed
    var showSettings: Bool = false

    // MARK: - Onboarding & Auth
    var hasCompletedOnboarding: Bool = false
    var isAuthenticated: Bool = false
    var username: String? = nil
    var userId: UUID? = nil

    // MARK: - Feed Progress
    /// 0.0 to 1.0 — current content display progress
    var feedProgress: Double = 0.0
    var isFeedPaused: Bool = false

    // MARK: - Camera
    /// When true, chrome (top bar + tab bar) is hidden for full-screen camera
    var isCameraActive: Bool = false

    // MARK: - Banners
    var showArchivedBanner: Bool = false

    // MARK: - Deep Links
    var pendingDeepLinkContentId: UUID?
    var deepLinkResult: DeepLinkResult?
    var showDeepLinkDialog: Bool = false

    // MARK: - App Readiness
    /// True after initial auth check completes
    var isReady: Bool = false
}
