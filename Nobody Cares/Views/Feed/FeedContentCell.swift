//
//  FeedContentCell.swift
//  Nobody Cares
//
//  Full-screen UICollectionViewCell for the vertical feed pager.
//  Bottom layer: UIImageView (thumbnail / placeholder — always non-nil).
//  Middle layer: PlayerContainerView (AVPlayerLayer for video).
//  Top layer: UIHostingController with the SwiftUI ContentOverlayView.
//
//  v2: Loading overlay, out-of-range overlay, never-black guarantee.
//

import AVKit
import SwiftUI
import UIKit

final class FeedContentCell: UICollectionViewCell {

    static let reuseId = "FeedContentCell"

    // MARK: - Media Layers

    let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = UIColor(white: 0.12, alpha: 1.0) // dark gray, not black
        return iv
    }()

    let playerView: PlayerContainerView = {
        let pv = PlayerContainerView()
        pv.backgroundColor = .clear  // transparent so poster shows through until video renders
        return pv
    }()

    // MARK: - Loading Overlay

    private let loadingContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        v.isHidden = true
        return v
    }()

    private let loadingSpinner: HourglassLoaderUIView = {
        let s = HourglassLoaderUIView(size: 32, color: .white)
        return s
    }()

    // MARK: - Out-of-Range Overlay

    private let outOfRangeContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        v.isHidden = true
        return v
    }()

    private let walkedAwayLabel: UILabel = {
        let l = UILabel()
        l.text = "WALKED AWAY"
        l.textColor = .white
        l.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .bold)
        l.textAlignment = .center
        return l
    }()

    private let moveCloserLabel: UILabel = {
        let l = UILabel()
        l.text = "Move closer to watch"
        l.textColor = UIColor.white.withAlphaComponent(0.7)
        l.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        l.textAlignment = .center
        return l
    }()

    // MARK: - Grace Period Overlay

    private let gracePeriodLabel: UILabel = {
        let l = UILabel()
        l.text = "Leaving range…"
        l.textColor = UIColor.white.withAlphaComponent(0.6)
        l.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        l.textAlignment = .center
        l.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        l.isHidden = true
        return l
    }()

    // MARK: - SwiftUI Overlay Host

    private var overlayHost: UIHostingController<ContentOverlayView>?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        backgroundColor = UIColor(white: 0.12, alpha: 1.0) // dark gray, not black
        contentView.backgroundColor = UIColor(white: 0.12, alpha: 1.0)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        outOfRangeContainer.translatesAutoresizingMaskIntoConstraints = false
        walkedAwayLabel.translatesAutoresizingMaskIntoConstraints = false
        moveCloserLabel.translatesAutoresizingMaskIntoConstraints = false
        gracePeriodLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(imageView)
        contentView.addSubview(playerView)
        contentView.addSubview(loadingContainer)
        loadingContainer.addSubview(loadingSpinner)
        contentView.addSubview(outOfRangeContainer)
        outOfRangeContainer.addSubview(walkedAwayLabel)
        outOfRangeContainer.addSubview(moveCloserLabel)
        contentView.addSubview(gracePeriodLabel)

        NSLayoutConstraint.activate([
            // Image layer (full screen)
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            // Player layer (full screen)
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            // Loading overlay (full screen)
            loadingContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            loadingContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            loadingContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            loadingContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: loadingContainer.centerYAnchor),

            // Out-of-range overlay (full screen)
            outOfRangeContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            outOfRangeContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            outOfRangeContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            outOfRangeContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            walkedAwayLabel.centerXAnchor.constraint(equalTo: outOfRangeContainer.centerXAnchor),
            walkedAwayLabel.centerYAnchor.constraint(equalTo: outOfRangeContainer.centerYAnchor, constant: -12),
            moveCloserLabel.topAnchor.constraint(equalTo: walkedAwayLabel.bottomAnchor, constant: 8),
            moveCloserLabel.centerXAnchor.constraint(equalTo: outOfRangeContainer.centerXAnchor),

            // Grace period label (bottom center, above HUD)
            gracePeriodLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -80),
            gracePeriodLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            gracePeriodLabel.widthAnchor.constraint(equalToConstant: 140),
            gracePeriodLabel.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Configure Media

    func configure(
        contentType: ContentType,
        player: AVPlayer?,
        preloadedImage: UIImage?,
        isMuted: Bool,
        isPlaying: Bool,
        isReady: Bool,
        rangeState: RangeState
    ) {
        // Always set a non-nil image — thumbnail, cached, or placeholder
        imageView.image = preloadedImage ?? MediaPreloader.placeholder

        // Update loading overlay.
        // For images, the content is effectively ready once we have the actual
        // image data (which may come from thumbnailCache even after readiness
        // was cleared by buffer eviction). Identity check against the static
        // placeholder distinguishes "real content" from "not yet loaded".
        let imageAlreadyLoaded = contentType == .image
            && preloadedImage != nil
            && preloadedImage !== MediaPreloader.placeholder
        let showLoading = !isReady && !imageAlreadyLoaded && rangeState != .outOfRange
        loadingContainer.isHidden = !showLoading
        loadingSpinner.isHidden = !showLoading

        // Update out-of-range overlay
        outOfRangeContainer.isHidden = rangeState != .outOfRange
        gracePeriodLabel.isHidden = rangeState != .gracePeriod

        // Video player
        switch contentType {
        case .video:
            if rangeState == .outOfRange {
                // Out of range — no playback, keep thumbnail visible
                playerView.player?.pause()
                playerView.player = nil
                playerView.isHidden = true
            } else if let player {
                playerView.player = player
                playerView.isHidden = false
                player.isMuted = isMuted
                if isPlaying && isReady {
                    player.play()
                } else {
                    player.pause()
                }
            } else {
                playerView.player = nil
                playerView.isHidden = true
            }

        case .image:
            playerView.player = nil
            playerView.isHidden = true
        }
    }

    // MARK: - Configure Overlay

    func configureOverlay(_ overlay: ContentOverlayView, parent: UIViewController) {
        if let host = overlayHost {
            host.rootView = overlay
        } else {
            let host = UIHostingController(rootView: overlay)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false

            parent.addChild(host)
            contentView.addSubview(host.view)
            host.didMove(toParent: parent)

            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])

            overlayHost = host
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        playerView.player?.pause()
        playerView.player = nil
        playerView.isHidden = true
        imageView.image = MediaPreloader.placeholder

        loadingContainer.isHidden = true
        loadingSpinner.isHidden = true
        outOfRangeContainer.isHidden = true
        gracePeriodLabel.isHidden = true

        overlayHost?.willMove(toParent: nil)
        overlayHost?.view.removeFromSuperview()
        overlayHost?.removeFromParent()
        overlayHost = nil
    }
}
