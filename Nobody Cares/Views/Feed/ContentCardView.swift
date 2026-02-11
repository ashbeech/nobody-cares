//
//  ContentCardView.swift
//  Nobody Cares
//
//  Full-screen content display — renders a single content item.
//
//  Per spec Section 9:
//  - Aspect-fill, no letterboxing
//  - Username chip (bottom-left) — tap for block/report options
//  - Right-side icon stack: mute, report, share
//  - Tap anywhere to toggle mute (video only)
//

import AVKit
import SwiftUI

// MARK: - Content Card View

struct ContentCardView: View {
    let item: ContentItem
    let isMuted: Bool
    let isPaused: Bool
    let onToggleMute: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void
    let onShare: () -> Void

    @State private var showUserActions = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Media content
            mediaView

            // Overlays
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    // Username chip (bottom-left) — tap for block/report
                    usernameChip
                    Spacer()
                    // Action icons (bottom-right)
                    actionStack
                }
                .padding(.horizontal, NCMetrics.contentPadding)
                .padding(.bottom, 12)
            }

            // User action tooltip
            if showUserActions {
                userActionOverlay
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if showUserActions {
                showUserActions = false
            } else if item.contentType == .video {
                onToggleMute()
            }
        }
    }

    // MARK: - Media View

    @ViewBuilder
    private var mediaView: some View {
        if let url = item.signedURL {
            switch item.contentType {
            case .image:
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        errorPlaceholder
                    case .empty:
                        loadingPlaceholder
                    @unknown default:
                        loadingPlaceholder
                    }
                }
                .ignoresSafeArea()

            case .video:
                VideoPlayerView(url: url, isMuted: isMuted, isPaused: isPaused)
                    .ignoresSafeArea()
            }
        } else {
            errorPlaceholder
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

    // MARK: - User Action Overlay (Block/Report tooltip)

    private var userActionOverlay: some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    tooltipButton(title: "BLOCK @\(item.username.uppercased())", icon: .block) {
                        showUserActions = false
                        onBlock()
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 1)

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
            // Mute indicator (video only)
            if item.contentType == .video {
                actionButton(icon: isMuted ? .speakerSlash : .speaker) {
                    onToggleMute()
                }
            }

            // Share
            actionButton(icon: .share) {
                onShare()
            }

            // Report
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

    // MARK: - Placeholders

    private var loadingPlaceholder: some View {
        ZStack {
            Color.black
            PixelIcon(type: .hourglass, size: 32, color: .white)
        }
    }

    private var errorPlaceholder: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                PixelIcon(type: .caution, size: 32, color: .white)
                Text("CONTENT UNAVAILABLE")
                    .font(NCFont.caption)
                    .foregroundColor(NCColor.dither)
            }
        }
    }
}

// MARK: - Video Player View

struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    let isMuted: Bool
    let isPaused: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let playerVC = AVPlayerViewController()
        let player = AVPlayer(url: url)
        player.isMuted = isMuted

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }

        playerVC.player = player
        playerVC.showsPlaybackControls = false
        playerVC.videoGravity = .resizeAspectFill
        playerVC.view.backgroundColor = .black

        if !isPaused {
            player.play()
        }

        return playerVC
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player?.isMuted = isMuted

        if isPaused {
            uiViewController.player?.pause()
        } else {
            uiViewController.player?.play()
        }
    }
}
