//
//  SettingsView.swift
//  Nobody Cares
//
//  Settings screen — Identity, Delete Account (geo-locked), About.
//
//  Per spec Section 12:
//  - Username display + "REASSIGN IDENTITY" button
//  - Geo-locked delete: must be within 10m of creation_point
//  - Email fallback: MFMailComposeViewController to delete@nobodycares.app
//  - About section with version label
//

import SwiftUI
import MessageUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AuthService.self) private var authService
    @Environment(PermissionService.self) private var permissionService
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var isRegenerating = false
    @State private var isCheckingLocation = false
    @State private var canDeleteLocally = false
    @State private var deletionLocationError: String?
    @State private var showMailError = false

    var body: some View {
        ZStack {
            NCColor.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                settingsTitleBar

                ScrollView {
                    VStack(spacing: 24) {
                        identitySection
                        deleteAccountSection
                        aboutSection
                        versionLabel
                    }
                    .padding(NCMetrics.contentPadding)
                }
            }
        }
        .task {
            await checkDeletionEligibility()
        }
        .retroDialog(isPresented: $showDeleteConfirm) {
            RetroDialog(
                title: "WARNING",
                icon: .caution,
                headline: "DELETE EVERYTHING",
                body_text: "This action is irreversible. Your content will be erased. Your username will be recycled. It will be as if you were never here. Which, in many ways, you weren't.",
                primaryAction: .init(title: "DELETE EVERYTHING") {
                    Task {
                        await performAccountDeletion()
                    }
                },
                secondaryAction: .init(title: "RECONSIDER") {
                    showDeleteConfirm = false
                }
            )
        }
        .retroDialog(isPresented: $showMailError) {
            RetroDialog(
                title: "ERROR",
                icon: .caution,
                headline: "MAIL UNAVAILABLE",
                body_text: "No email client is configured. Send a deletion request manually to delete@nobodycares.app with your user ID: \(appState.userId?.uuidString ?? "unknown")",
                primaryAction: .init(title: "DISMISS") {
                    showMailError = false
                }
            )
        }
    }

    // MARK: - Title Bar

    private var settingsTitleBar: some View {
        ZStack {
            DitherPatternView(style: .stripes)

            Text("SETTINGS")
                .font(NCFont.dialogTitle)
                .foregroundColor(NCColor.ink)
                .tracking(1)
                .padding(.horizontal, 8)
                .background(NCColor.background)

            HStack {
                Button(action: { dismiss() }) {
                    Rectangle()
                        .stroke(NCColor.ink, lineWidth: 1.5)
                        .frame(width: NCMetrics.closeBoxSize, height: NCMetrics.closeBoxSize)
                        .background(NCColor.background)
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                Spacer()
            }
        }
        .frame(height: NCMetrics.titleBarHeight)
        .overlay(
            Rectangle()
                .frame(height: NCMetrics.borderWidth)
                .foregroundColor(NCColor.ink),
            alignment: .bottom
        )
    }

    // MARK: - Identity

    private var identitySection: some View {
        RetroWindow(title: "IDENTITY") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("@")
                        .font(NCFont.body(16))
                        .foregroundColor(NCColor.inkSecondary)
                    Text(authService.username ?? appState.username ?? "unassigned")
                        .font(NCFont.display(16))
                        .foregroundColor(NCColor.ink)
                }

                RetroButton(
                    title: isRegenerating ? "REASSIGNING..." : "REASSIGN IDENTITY",
                    variant: .secondary,
                    isEnabled: !isRegenerating
                ) {
                    Task {
                        isRegenerating = true
                        defer { isRegenerating = false }
                        do {
                            try await authService.regenerateUsername()
                            appState.username = authService.username
                            AnalyticsService.shared.track(.identityReassigned)
                        } catch {
                            // Silent fail — nobody cares
                        }
                    }
                }
            }
            .padding(NCMetrics.dialogPadding)
        }
    }

    // MARK: - Delete Account

    private var deleteAccountSection: some View {
        RetroWindow(title: "DANGER ZONE", icon: .caution) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Account deletion requires you to physically return to the location where your account was created.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                if let error = deletionLocationError {
                    Text(error)
                        .font(NCFont.caption)
                        .foregroundColor(NCColor.error)
                        .lineSpacing(2)
                }

                if isCheckingLocation {
                    HStack(spacing: 8) {
                        PixelIcon(type: .hourglass, size: 14)
                        Text("CHECKING LOCATION...")
                            .font(NCFont.caption)
                            .foregroundColor(NCColor.inkSecondary)
                    }
                }

                RetroButton(
                    title: "DELETE ACCOUNT",
                    variant: .primary,
                    isEnabled: canDeleteLocally
                ) {
                    showDeleteConfirm = true
                }

                RetroButton(title: "REQUEST DELETION VIA EMAIL", variant: .secondary) {
                    openDeletionEmail()
                }
            }
            .padding(NCMetrics.dialogPadding)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        RetroWindow(title: "ABOUT") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nobody Cares is a geo-locked content platform.")
                    .font(NCFont.display(13))
                    .foregroundColor(NCColor.ink)

                Text("Content only exists where it was made. If you're not there, it's not there. Nobody cares.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .lineSpacing(4)

                Text("There is no algorithm. There is no feed curation. There are no followers. There is only proximity. And even that is temporary.")
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.inkSecondary)
                    .lineSpacing(4)
            }
            .padding(NCMetrics.dialogPadding)
        }
    }

    // MARK: - Version

    private var versionLabel: some View {
        Text("VERSION 1.0. THERE MAY NOT BE ANOTHER.")
            .font(NCFont.caption)
            .foregroundColor(NCColor.inkSecondary)
            .tracking(0.5)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    // MARK: - Geo-locked Deletion Check

    private func checkDeletionEligibility() async {
        isCheckingLocation = true
        defer { isCheckingLocation = false }

        // Fetch user's creation location from DB
        guard let userId = appState.userId else {
            deletionLocationError = "USER IDENTITY NOT FOUND."
            return
        }

        do {
            struct UserLocation: Decodable {
                let creationLat: Double?
                let creationLng: Double?

                enum CodingKeys: String, CodingKey {
                    case creationLat = "creation_lat"
                    case creationLng = "creation_lng"
                }
            }

            let profile: UserLocation = try await supabase
                .from("users")
                .select("creation_lat, creation_lng")
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value

            guard let creationLat = profile.creationLat,
                  let creationLng = profile.creationLng else {
                deletionLocationError = "CREATION LOCATION NOT RECORDED. Use email deletion instead."
                return
            }

            // Get current location
            guard let currentLocation = await permissionService.fetchCurrentLocation() else {
                deletionLocationError = "CURRENT LOCATION UNAVAILABLE."
                return
            }

            let creationLocation = CLLocation(latitude: creationLat, longitude: creationLng)
            let distance = currentLocation.distance(from: creationLocation)

            if distance <= 10.0 {
                canDeleteLocally = true
                deletionLocationError = nil
            } else {
                canDeleteLocally = false
                deletionLocationError = "YOU ARE \(Int(distance))M FROM YOUR CREATION POINT. Move within 10m to enable local deletion."
            }
        } catch {
            deletionLocationError = "FAILED TO CHECK LOCATION."
        }
    }

    // MARK: - Account Deletion

    private func performAccountDeletion() async {
        AnalyticsService.shared.track(.accountDeleted)
        await authService.signOut()
        KeychainService.shared.deleteAll()
        await MainActor.run {
            appState.hasCompletedOnboarding = false
            appState.isAuthenticated = false
            showDeleteConfirm = false
            dismiss()
        }
    }

    // MARK: - Email Deletion

    private func openDeletionEmail() {
        let userId = appState.userId?.uuidString ?? "unknown"
        let subject = "Content Deletion Request — \(userId)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = "I request deletion of my account and all associated data. User ID: \(userId). I understand this is irreversible."
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let mailto = "mailto:delete@nobodycares.app?subject=\(subject)&body=\(body)"

        if let url = URL(string: mailto) {
            UIApplication.shared.open(url) { success in
                if !success {
                    showMailError = true
                }
            }
        } else {
            showMailError = true
        }
    }
}

import CoreLocation

#Preview("Settings") {
    SettingsView()
        .environment(AppState())
        .environment(AuthService())
        .environment(PermissionService())
}
