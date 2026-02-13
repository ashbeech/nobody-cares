//
//  EmptyFeedView.swift
//  Nobody Cares
//
//  Empty state — "0 CONTENT LOCAL TO YOU"
//  Retro system alert dialog over dithered background.
//
//  Pull-to-refresh: drag down to reveal a floating hourglass that tracks the
//  pull gesture. Release past threshold to trigger a proximity re-check.
//

import SwiftUI

struct EmptyFeedView: View {
    var isRefreshing: Bool = false
    var onMakeContent: () -> Void = {}
    var onRefresh: () -> Void = {}

    // MARK: - Pull-to-Refresh State

    @State private var pullOffset: CGFloat = 0

    private let pullThreshold: CGFloat = 80

    // MARK: - Body

    var body: some View {
        ZStack {
            // Parent provides animated dither background

            // Floating hourglass — visible during pull-down drag or active refresh
            if pullOffset > 10 || isRefreshing {
                VStack {
                    HourglassLoader(size: 28, color: NCColor.ink)
                        .padding(.top, hourglassTopPadding)
                        .opacity(hourglassOpacity)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.15), value: isRefreshing)
            }

            // Alert dialog
            RetroWindow(title: "ALERT", icon: .caution) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("NOBODY CARES:\n0 CONTENT LOCAL TO YOU")
                        .font(NCFont.display(16))
                        .foregroundColor(NCColor.ink)
                        .tracking(0.5)

                    Text("This area has been assessed for interest. None was found.")
                        .font(NCFont.dialogBody)
                        .foregroundColor(NCColor.ink)
                        .lineSpacing(4)

                    HStack(spacing: 12) {
                        Spacer()
                        RetroButton(
                            title: "REFRESH",
                            variant: .secondary,
                            isEnabled: !isRefreshing,
                            trailingIcon: .recycle
                        ) {
                            onRefresh()
                        }
                        RetroButton(title: "MAKE CONTENT", variant: .primary) {
                            onMakeContent()
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(NCMetrics.dialogPadding)
            }
            .padding(.horizontal, 32)
            .offset(y: pullOffset > 0 ? pullOffset * 0.3 : 0)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: pullOffset)
        .gesture(pullToRefreshGesture)
    }

    // MARK: - Pull-to-Refresh Gesture

    private var pullToRefreshGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isRefreshing else { return }
                let translation = value.translation.height
                if translation > 0 {
                    // Rubber-band: diminishing return past threshold
                    if translation < pullThreshold {
                        pullOffset = translation
                    } else {
                        let overshoot = translation - pullThreshold
                        pullOffset = pullThreshold + overshoot * 0.3
                    }
                }
            }
            .onEnded { _ in
                guard !isRefreshing else { return }
                if pullOffset >= pullThreshold * 0.6 {
                    onRefresh()
                }
                pullOffset = 0
            }
    }

    // MARK: - Hourglass Positioning

    /// During pull: tracks finger. During refresh (post-release): fixed position.
    private var hourglassTopPadding: CGFloat {
        if pullOffset > 10 {
            return pullOffset - 10
        }
        // Resting position during active refresh
        return 20
    }

    /// Fades in during pull; fully opaque during active refresh.
    private var hourglassOpacity: Double {
        if pullOffset > 10 {
            return min(Double(pullOffset - 10) / 40.0, 1.0)
        }
        return 1.0
    }
}

#Preview("Empty Feed") {
    EmptyFeedView()
}

#Preview("Empty Feed — Refreshing") {
    EmptyFeedView(isRefreshing: true)
}
