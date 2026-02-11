//
//  Nobody_CaresApp.swift
//  Nobody Cares
//
//  Created by Ashley Davison on 11/02/2026.
//

import SwiftUI

@main
struct Nobody_CaresApp: App {
    @State private var appState = AppState()
    @State private var authService = AuthService()
    @State private var permissionService = PermissionService()
    @State private var apiGuard = APIGuard()
    @State private var appAttestService = AppAttestService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(appState)
                .environment(authService)
                .environment(permissionService)
                .environment(apiGuard)
                .environment(appAttestService)
                .preferredColorScheme(.light) // Spec: monochrome, no dark mode
                .task {
                    await initializeApp()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        // Recheck permissions every time app becomes active
                        // (catches Settings changes, "Allow Once" expiry, etc.)
                        permissionService.refreshLocationStatus()
                    }
                }
        }
    }

    // MARK: - Root View

    @ViewBuilder
    private var rootView: some View {
        if !appState.isReady {
            // Splash — checking for existing session
            splashView
        } else if apiGuard.isBanned {
            // Permanently banned
            BannedView()
        } else if !appState.hasCompletedOnboarding {
            // First launch — onboarding flow
            OnboardingView()
        } else if !permissionService.isLocationAuthorized {
            // Location expired ("Allow Once") or revoked — hard gate
            LocationGateView()
        } else {
            // Authenticated + location granted — main app
            MainShell()
        }
    }

    // MARK: - Splash

    private var splashView: some View {
        ZStack {
            NCColor.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("NOBODY CARES")
                    .font(NCFont.display(28))
                    .foregroundColor(NCColor.ink)
                    .tracking(2)

                PixelIcon(type: .hourglass, size: 32)
            }
        }
    }

    // MARK: - Initialization

    private func initializeApp() async {
        // Load any existing App Attest key from Keychain
        appAttestService.initialize()

        // Check for existing Supabase session
        await authService.initialize()

        if authService.isAuthenticated {
            // Check if user is banned
            await apiGuard.checkBanStatus()
        }

        await MainActor.run {
            if authService.isAuthenticated {
                // Returning user — skip onboarding
                appState.isAuthenticated = true
                appState.username = authService.username
                appState.userId = authService.userId
                appState.hasCompletedOnboarding = true
            }
            // else: new user or expired session → show onboarding

            appState.isReady = true
        }
    }

    // MARK: - Deep Link Handling

    private func handleDeepLink(_ url: URL) {
        guard let contentId = DeepLinkHandler.shared.parseContentId(from: url) else { return }

        // Store the pending deep link — resolve when the app is ready
        appState.pendingDeepLinkContentId = contentId

        guard appState.isReady, appState.isAuthenticated else { return }

        Task {
            let location = await permissionService.fetchCurrentLocation()
            let result = await DeepLinkHandler.shared.resolve(
                contentId: contentId,
                currentLocation: location
            )

            await MainActor.run {
                appState.deepLinkResult = result
                appState.showDeepLinkDialog = true
                appState.pendingDeepLinkContentId = nil
            }
        }
    }
}
