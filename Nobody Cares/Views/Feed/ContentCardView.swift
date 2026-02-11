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
    var currentUserId: UUID? = nil
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
                    // Only show block option when it's not the user's own content
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

// MARK: - Video Player View (AVPlayerLayer — no built-in gesture handling)

struct VideoPlayerView: UIViewRepresentable {
    let url: URL
    let isMuted: Bool
    let isPaused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        view.player = player

        context.coordinator.player = player
        context.coordinator.observeLoop(player: player)

        if !isPaused {
            player.play()
        }

        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.player?.isMuted = isMuted

        if isPaused {
            uiView.player?.pause()
        } else {
            uiView.player?.play()
        }
    }

    class Coordinator {
        var player: AVPlayer?
        private var loopObserver: NSObjectProtocol?

        func observeLoop(player: AVPlayer) {
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }

        deinit {
            if let observer = loopObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - Player Container (AVPlayerLayer — touch-transparent)

class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
