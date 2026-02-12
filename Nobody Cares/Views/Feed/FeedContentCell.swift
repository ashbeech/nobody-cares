//
//  FeedContentCell.swift
//  Nobody Cares
//
//  Full-screen UICollectionViewCell for the vertical feed pager.
//  Bottom layer: UIImageView (poster / preloaded image).
//  Middle layer: PlayerContainerView (AVPlayerLayer for video).
//  Top layer: UIHostingController with the SwiftUI ContentOverlayView.
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
        iv.backgroundColor = .black
        return iv
    }()

    let playerView: PlayerContainerView = {
        let pv = PlayerContainerView()
        pv.backgroundColor = .clear  // transparent so poster shows through until video renders
        return pv
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
        backgroundColor = .black
        contentView.backgroundColor = .black

        imageView.translatesAutoresizingMaskIntoConstraints = false
        playerView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(imageView)
        contentView.addSubview(playerView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    // MARK: - Configure Media

    func configure(
        contentType: ContentType,
        player: AVPlayer?,
        preloadedImage: UIImage?,
        isMuted: Bool,
        isPlaying: Bool
    ) {
        // Always show the preloaded image as a base / poster
        imageView.image = preloadedImage

        switch contentType {
        case .video:
            if let player {
                playerView.player = player
                playerView.isHidden = false
                player.isMuted = isMuted
                if isPlaying {
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
        imageView.image = nil

        overlayHost?.willMove(toParent: nil)
        overlayHost?.view.removeFromSuperview()
        overlayHost?.removeFromParent()
        overlayHost = nil
    }
}
