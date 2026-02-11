//
//  LoadingFeedView.swift
//  Nobody Cares
//
//  Loading state — hourglass animation + "SEARCHING FOR LOCAL CONTENT..."
//

import SwiftUI

struct LoadingFeedView: View {
    @State private var hourglassFlipped = false

    var body: some View {
        VStack(spacing: 24) {
            // Hourglass — 2-frame flip animation, 500ms per frame
            PixelIcon(
                type: .hourglass,
                size: 48,
                color: NCColor.ink
            )
            .rotationEffect(.degrees(hourglassFlipped ? 180 : 0))
            .onAppear {
                withAnimation(
                    .linear(duration: 0.001)
                    .repeatForever(autoreverses: false)
                ) {
                    // Use a timer for stepped animation (no easing)
                }
                startHourglassAnimation()
            }

            Text("SEARCHING FOR LOCAL CONTENT\u{2026}")
                .font(NCFont.body(16))
                .foregroundColor(NCColor.ink)
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private func startHourglassAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            hourglassFlipped.toggle()
        }
    }
}

#Preview("Loading Feed") {
    LoadingFeedView()
}
