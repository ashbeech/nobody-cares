//
//  HourglassLoader.swift
//  Nobody Cares
//
//  Centralised loading indicator — animated hourglass flip.
//  Use this component EVERYWHERE a loading state is needed.
//
//  SwiftUI:  HourglassLoader(size: 32, color: .white)
//  UIKit:    HourglassLoaderUIView(size: 32, color: .white)
//

import SwiftUI
import UIKit

// MARK: - SwiftUI Component

/// Animated hourglass loader — the single loading indicator for the entire app.
/// Flips 180° every 500ms in a stepped (non-eased) animation.
struct HourglassLoader: View {
    var size: CGFloat = 32
    var color: Color = NCColor.ink

    @State private var flipped = false

    var body: some View {
        PixelIcon(
            type: .hourglass,
            size: size,
            color: color
        )
        .rotationEffect(.degrees(flipped ? 180 : 0))
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            flipped.toggle()
        }
    }
}

// MARK: - UIKit Component

/// UIKit wrapper for HourglassLoader — drop-in replacement for UIActivityIndicatorView.
final class HourglassLoaderUIView: UIView {

    private let hostingController: UIHostingController<HourglassLoader>

    init(size: CGFloat = 32, color: Color = .white) {
        let loader = HourglassLoader(size: size, color: color)
        self.hostingController = UIHostingController(rootView: loader)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.centerXAnchor.constraint(equalTo: centerXAnchor),
            hostingController.view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

// MARK: - Preview

#Preview("Hourglass Loader") {
    VStack(spacing: 32) {
        HourglassLoader(size: 48, color: NCColor.ink)
        HourglassLoader(size: 32, color: .white)
        HourglassLoader(size: 14, color: NCColor.inkSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.gray)
}
