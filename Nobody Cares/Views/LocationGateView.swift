//
//  LocationGateView.swift
//  Nobody Cares
//
//  Hard gate that blocks the entire app when location permission
//  is not granted. Covers two states:
//
//  1. `.notDetermined` — "Allow Once" expired or first launch after
//     onboarding. Can re-trigger the system prompt.
//
//  2. `.denied` / `.restricted` — User explicitly denied or revoked
//     in Settings. Must open Settings to re-enable.
//
//  The app is completely bricked behind this view. There is no way
//  past it without granting location access.
//

import SwiftUI
import CoreLocation

struct LocationGateView: View {
    @Environment(PermissionService.self) private var permissionService
    @Environment(\.scenePhase) private var scenePhase

    /// Track whether we just sent the user to Settings, so we can
    /// recheck permission when they return.
    @State private var sentToSettings = false

    /// Whether the system prompt has been triggered this session
    /// (to prevent rapid re-taps while the prompt is visible).
    @State private var promptPending = false

    private var isDenied: Bool {
        permissionService.locationStatus == .denied
            || permissionService.locationStatus == .restricted
    }

    var body: some View {
        ZStack {
            NCColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                Text("NOBODY CARES")
                    .font(NCFont.display(28))
                    .foregroundColor(NCColor.ink)
                    .tracking(2)
                    .padding(.bottom, 32)

                // Gate dialog
                RetroWindow(title: isDenied ? "ACCESS REVOKED" : "LOCATION REQUIRED", icon: .lock) {
                    VStack(alignment: .leading, spacing: 16) {
                        if isDenied {
                            deniedContent
                        } else {
                            notDeterminedContent
                        }
                    }
                    .padding(NCMetrics.dialogPadding)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Recheck permission when returning from Settings or background
                permissionService.refreshLocationStatus()
                promptPending = false
            }
        }
        .onChange(of: permissionService.locationStatus) { _, _ in
            promptPending = false
        }
    }

    // MARK: - Not Determined (can re-prompt)

    private var notDeterminedContent: some View {
        Group {
            Text("LOCATION ACCESS HAS EXPIRED.")
                .font(NCFont.display(14))
                .foregroundColor(NCColor.ink)

            Text("This app requires continuous location access to function. Without it, there is nothing here for you. There may be nothing here for you regardless, but without location access there is definitely nothing.")
                .font(NCFont.dialogBody)
                .foregroundColor(NCColor.ink)
                .lineSpacing(4)

            Text("Select \"While Using the App\" and enable Precise Location.")
                .font(NCFont.dialogBody)
                .foregroundColor(NCColor.ink)
                .lineSpacing(4)

            HStack {
                Spacer()
                RetroButton(title: "GRANT ACCESS", variant: .primary) {
                    guard !promptPending else { return }
                    promptPending = true
                    permissionService.requestLocationPermission()
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Denied (must go to Settings)

    private var deniedContent: some View {
        Group {
            Text("LOCATION ACCESS DENIED.")
                .font(NCFont.display(14))
                .foregroundColor(NCColor.ink)

            Text("You have denied location access. This app is a geo-locked content platform. Without location, it is an empty screen. Which, frankly, is an improvement over most of what gets posted here.")
                .font(NCFont.dialogBody)
                .foregroundColor(NCColor.ink)
                .lineSpacing(4)

            Text("If you do not wish to share your location, we understand. Might we suggest an alternative platform where location is irrelevant and the content is equally meaningless?")
                .font(NCFont.dialogBody)
                .foregroundColor(NCColor.ink)
                .lineSpacing(4)

            HStack(spacing: 12) {
                Spacer()
                RetroButton(title: "BACK TO FACEBOOK", variant: .secondary) {
                    // Do nothing — the app stays bricked. This is a joke button.
                    // (There is no Facebook deep link. The button is decorative cruelty.)
                }
                RetroButton(title: "OPEN SETTINGS", variant: .primary) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                        sentToSettings = true
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

#Preview("Location Gate — Not Determined") {
    LocationGateView()
        .environment(PermissionService())
}
