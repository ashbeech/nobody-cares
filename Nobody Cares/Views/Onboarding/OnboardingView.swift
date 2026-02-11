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
    @State private var loadingMessage: String = ""
    @State private var hourglassFlipped = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        ZStack {
            NCColor.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                if isProcessing {
                    // Loading state — hourglass + status message
                    onboardingLoadingView
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                } else {
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
                        .transition(.opacity)
                }

                Spacer()
            }
            .animation(.linear(duration: 0.15), value: isProcessing)
        }
        .onChange(of: permissionService.locationStatus) { _, newStatus in
            guard step == .location else { return }
            if permissionService.isLocationAuthorized {
                // Granted (including after returning from Settings)
                showError = false
                advanceStep()
            } else if newStatus != .notDetermined {
                // Denied or restricted
                errorMessage = "LOCATION DENIED. Without location access, this app is an empty room. Which, to be fair, it mostly is anyway.\n\nOpen Settings and grant location access, or get back to Facebook."
                showError = true
            }
        }
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

    // MARK: - Loading View

    private var onboardingLoadingView: some View {
        RetroWindow(title: "PROCESSING") {
            VStack(spacing: 20) {
                PixelIcon(
                    type: .hourglass,
                    size: 36,
                    color: NCColor.ink
                )
                .rotationEffect(.degrees(hourglassFlipped ? 180 : 0))
                .onAppear { startHourglassAnimation() }

                Text(loadingMessage)
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .animation(.none, value: loadingMessage)
            }
            .frame(maxWidth: .infinity)
            .padding(NCMetrics.dialogPadding)
            .padding(.vertical, 8)
        }
    }

    private func startHourglassAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            hourglassFlipped.toggle()
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
        loadingMessage = "Locating you on the planet\u{2026}\nThe satellite has been informed of your existence."
        isProcessing = true

        Task {
            do {
                // 1. Get current location for registration
                let location = await permissionService.fetchCurrentLocation()

                // 2. Create anonymous auth session
                await MainActor.run {
                    loadingMessage = "Generating anonymous identity\u{2026}\nYou were already nobody. We\u{2019}re making it official."
                }
                try await authService.signInAnonymously()

                // 3. Register user profile with location
                await MainActor.run {
                    loadingMessage = "Filing your paperwork\u{2026}\nYour application for irrelevance is being processed."
                }
                try await authService.registerUser(
                    latitude: location?.coordinate.latitude,
                    longitude: location?.coordinate.longitude
                )

                // 4. Perform App Attest (silently, non-blocking for onboarding)
                //    Attestation failure on simulator/debug is expected and handled.
                await MainActor.run {
                    loadingMessage = "Verifying device authenticity\u{2026}\nConfirming your hardware is real. Unlike your future content."
                }
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
                    loadingMessage = "Preparing your personalised void\u{2026}"
                }
                // Brief pause so the user can read the final message
                try? await Task.sleep(for: .milliseconds(600))

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
