//
//  EndOfFeedView.swift
//  Nobody Cares
//
//  End-of-feed state — "NO MORE LOCAL CONTENT. DOPAMINE DROP IMMINENT."
//

import SwiftUI

struct EndOfFeedView: View {
    var onMakeContent: () -> Void = {}
    var onRefresh: () -> Void = {}

    var body: some View {
        ZStack {
            // Background dither
            DitherPatternView(
                style: .light,
                foreground: NCColor.dither,
                background: NCColor.background
            )
            .ignoresSafeArea()

            // Warning dialog
            RetroWindow(title: "WARNING", icon: .caution) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("NO MORE LOCAL CONTENT")
                        .font(NCFont.display(16))
                        .foregroundColor(NCColor.ink)
                        .tracking(0.5)

                    Text("DOPAMINE DROP IMMINENT")
                        .font(NCFont.display(14))
                        .foregroundColor(NCColor.ink)
                        .tracking(0.5)

                    Text("Please vacate the area or produce more content.")
                        .font(NCFont.dialogBody)
                        .foregroundColor(NCColor.ink)
                        .lineSpacing(4)

                    HStack(spacing: 12) {
                        Spacer()
                        RetroButton(title: "REFRESH", variant: .secondary) {
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
        }
    }
}

#Preview("End of Feed") {
    EndOfFeedView()
}
