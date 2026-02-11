//
//  OnboardingView.swift
//  Nobody Cares
//
//  4-screen onboarding: Welcome → Location → Camera → Microphone.
//  Retro system dialog aesthetic. Bureaucratic Scarfolk-inspired copy.
//  After completion: anonymous auth → register user → feed.
//

import SwiftUI

// MARK: - Onboarding Steps

private enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case location = 1
    case camera = 2
    case microphone = 3
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @Environment(AuthService.self) private var authService
    @Environment(PermissionService.self) private var permissionService
    @Environment(AppState.self) private var appState
    @Environment(AppAttestService.self) private var appAttestService

    @State private var step: OnboardingStep = .welcome
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var captchaToken: String?
    @State private var showCaptcha = false

    var body: some View {
        ZStack {
            NCColor.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo (on welcome screen)
                if step == .welcome {
                    Text("NOBODY CARES")
                        .font(NCFont.display(28))
                        .foregroundColor(NCColor.ink)
                        .tracking(2)
                        .padding(.bottom, 32)
                }

                // Dialog for current step
                currentStepDialog
                    .padding(.horizontal, 24)

                Spacer()
            }
        }
        .onChange(of: permissionService.locationStatus) { _, newStatus in
            if step == .location && newStatus != .notDetermined {
                if permissionService.isLocationAuthorized {
                    advanceStep()
                } else {
                    errorMessage = "LOCATION DENIED. Without location access, this app is an empty room. Which, to be fair, it mostly is anyway."
                    showError = true
                }
            }
        }
        .overlay {
            if showCaptcha {
                CaptchaChallengeView(
                    onToken: { token in
                        showCaptcha = false
                        finalizeRegistration(captchaToken: token)
                    },
                    onDismiss: {
                        showCaptcha = false
                        isProcessing = false
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.linear(duration: 0.2), value: showCaptcha)
        .retroDialog(isPresented: $showError) {
            RetroDialog(
                title: "ERROR",
                icon: .caution,
                headline: "PERMISSION DENIED",
                body_text: errorMessage,
                primaryAction: .init(title: "OPEN SETTINGS") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    showError = false
                },
                secondaryAction: .init(title: "DISMISS") {
                    showError = false
                }
            )
        }
    }

    // MARK: - Step Dialogs

    @ViewBuilder
    private var currentStepDialog: some View {
        switch step {
        case .welcome:
            welcomeDialog
        case .location:
            locationDialog
        case .camera:
            cameraDialog
        case .microphone:
            microphoneDialog
        }
    }

    // MARK: - Screen 1: Welcome

    private var welcomeDialog: some View {
        RetroWindow(title: "NOTICE") {
            VStack(alignment: .leading, spacing: 16) {
                Text("You are about to install a geo-locked content platform on your personal device.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                Text("This software will request access to your location, camera, and microphone.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                Text("Compliance is appreciated.")
                    .font(NCFont.display(14))
                    .foregroundColor(NCColor.ink)

                Text("By proceeding, you confirm that you accept this and everything else, forever.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                HStack {
                    Spacer()
                    RetroButton(title: "PROCEED", variant: .primary) {
                        advanceStep()
                    }
                }
                .padding(.top, 4)
            }
            .padding(NCMetrics.dialogPadding)
        }
    }

    // MARK: - Screen 2: Location Permission

    private var locationDialog: some View {
        RetroWindow(title: "LOCATION ACCESS") {
            VStack(alignment: .leading, spacing: 16) {
                Text("We need to know where you are at all times.")
                    .font(NCFont.display(14))
                    .foregroundColor(NCColor.ink)

                Text("This information will be used to determine whether any content near you is worth showing you. Early indications suggest it is not.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                Text("Select \"Precise\" and \"While Using the App.\"")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                HStack {
                    Spacer()
                    RetroButton(title: "GRANT ACCESS", variant: .primary) {
                        permissionService.requestLocationPermission()
                    }
                }
                .padding(.top, 4)
            }
            .padding(NCMetrics.dialogPadding)
        }
    }

    // MARK: - Screen 3: Camera Permission

    private var cameraDialog: some View {
        RetroWindow(title: "CAMERA ACCESS") {
            VStack(alignment: .leading, spacing: 16) {
                Text("The camera is required to produce content.")
                    .font(NCFont.display(14))
                    .foregroundColor(NCColor.ink)

                Text("We cannot guarantee the content you produce will be of any value to anyone, including yourself.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                Text("Proceed with this understanding.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                HStack {
                    Spacer()
                    RetroButton(title: "GRANT ACCESS", variant: .primary) {
                        Task {
                            let granted = await permissionService.requestCameraPermission()
                            if granted {
                                advanceStep()
                            } else {
                                errorMessage = "CAMERA DENIED. You may observe, but you may not contribute. A familiar dynamic."
                                showError = true
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(NCMetrics.dialogPadding)
        }
    }

    // MARK: - Screen 4: Microphone Permission

    private var microphoneDialog: some View {
        RetroWindow(title: "MICROPHONE ACCESS") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Audio capture is optional but recommended.")
                    .font(NCFont.display(14))
                    .foregroundColor(NCColor.ink)

                Text("Your ambient sounds may be the most interesting thing about you.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                HStack(spacing: 12) {
                    Spacer()
                    RetroButton(title: "SKIP", variant: .secondary) {
                        completeOnboarding()
                    }
                    RetroButton(title: "GRANT ACCESS", variant: .primary) {
                        Task {
                            _ = await permissionService.requestMicrophonePermission()
                            completeOnboarding()
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(NCMetrics.dialogPadding)
        }
    }

    // MARK: - Navigation

    private func advanceStep() {
        guard let nextStep = OnboardingStep(rawValue: step.rawValue + 1) else {
            completeOnboarding()
            return
        }
        withAnimation(.linear(duration: 0.15)) {
            step = nextStep
        }
    }

    // MARK: - Complete Onboarding

    private func completeOnboarding() {
        guard !isProcessing else { return }
        isProcessing = true

        // Show captcha challenge to get a Turnstile token before sign-in
        showCaptcha = true
    }

    /// Called after CAPTCHA token is obtained (or skipped in dev)
    private func finalizeRegistration(captchaToken: String?) {
        Task {
            do {
                // 1. Get current location for registration
                let location = await permissionService.fetchCurrentLocation()

                // 2. Create anonymous auth session with CAPTCHA token
                try await authService.signInAnonymously(captchaToken: captchaToken)

                // 3. Register user profile with location
                try await authService.registerUser(
                    latitude: location?.coordinate.latitude,
                    longitude: location?.coordinate.longitude
                )

                // 4. Perform App Attest (silently, non-blocking for onboarding)
                //    Attestation failure on simulator/debug is expected and handled.
                do {
                    try await appAttestService.performAttestation()
                } catch {
                    #if DEBUG
                    print("[Onboarding] App Attest skipped: \(error.localizedDescription)")
                    #endif
                    // Non-fatal — attestation can be retried later
                }

                // 5. Update app state
                await MainActor.run {
                    appState.isAuthenticated = true
                    appState.username = authService.username
                    appState.userId = authService.userId
                    appState.hasCompletedOnboarding = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Registration failed. The void is not accepting new members at this time."
                    showError = true
                    isProcessing = false
                    showCaptcha = false
                }
            }
        }
    }
}

#Preview("Onboarding") {
    OnboardingView()
        .environment(AuthService())
        .environment(PermissionService())
        .environment(AppState())
        .environment(AppAttestService())
}
