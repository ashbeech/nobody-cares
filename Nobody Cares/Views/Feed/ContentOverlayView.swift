//
//  ContentOverlayView.swift
//  Nobody Cares
//
//  Transparent SwiftUI overlay rendered on top of each feed cell.
//  Handles: username chip, action icons, block/report tooltip, and
//  full-area tap for video mute toggle.
//

import SwiftUI

struct ContentOverlayView: View {
    let item: ContentItem
    let isMuted: Bool
    var currentUserId: UUID? = nil
    let onToggleMute: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void
    let onShare: () -> Void

    @State private var showUserActions = false

    var body: some View {
        ZStack {
            // Full-area invisible tap target
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if showUserActions {
                        withAnimation(.linear(duration: 0.1)) {
                            showUserActions = false
                        }
                    } else if item.contentType == .video {
                        onToggleMute()
                    }
                }

            // Bottom HUD
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    usernameChip
                    Spacer()
                    actionStack
                }
                .padding(.horizontal, NCMetrics.contentPadding)
                .padding(.bottom, 12)
            }

            // Block / Report tooltip
            if showUserActions {
                userActionOverlay
            }
        }
    }

    // MARK: - Username Chip

    private var usernameChip: some View {
        Button {
            withAnimation(.linear(duration: 0.1)) {
                showUserActions.toggle()
            }
        } label: {
            Text(item.username)
                .font(NCFont.body(12))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.65))
                .retroBorder(color: Color.white.opacity(0.3), width: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - User Action Overlay

    private var userActionOverlay: some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    if item.userId != currentUserId {
                        tooltipButton(title: "BLOCK @\(item.username.uppercased())", icon: .block) {
                            showUserActions = false
                            onBlock()
                        }

                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 1)
                    }

                    tooltipButton(title: "REPORT CONTENT", icon: .flag) {
                        showUserActions = false
                        onReport()
                    }
                }
                .background(Color.black.opacity(0.85))
                .retroBorder(color: Color.white.opacity(0.4), width: 1)
                .frame(maxWidth: 240)

                Spacer()
            }
            .padding(.horizontal, NCMetrics.contentPadding)
            .padding(.bottom, 48)
        }
        .transition(.opacity)
    }

    private func tooltipButton(title: String, icon: PixelIconType, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PixelIcon(type: icon, size: 16, color: .white)
                Text(title)
                    .font(NCFont.body(11))
                    .foregroundColor(.white)
                    .tracking(0.3)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action Stack

    private var actionStack: some View {
        VStack(spacing: 16) {
            if item.contentType == .video {
                actionButton(icon: isMuted ? .speakerSlash : .speaker) {
                    onToggleMute()
                }
            }

            actionButton(icon: .share) {
                onShare()
            }

            actionButton(icon: .flag) {
                onReport()
            }
        }
    }

    private func actionButton(icon: PixelIconType, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PixelIcon(type: icon, size: 22, color: .white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.45))
                .retroBorder(color: Color.white.opacity(0.3), width: 1)
        }
        .buttonStyle(.plain)
    }
}
