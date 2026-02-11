//
//  EmptyFeedView.swift
//  Nobody Cares
//
//  Empty state — "0 CONTENT LOCAL TO YOU"
//  Retro system alert dialog over dithered background.
//

import SwiftUI

struct EmptyFeedView: View {
    var onMakeContent: () -> Void = {}

    var body: some View {
        ZStack {
            // Parent provides animated dither background

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

                    HStack {
                        Spacer()
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

#Preview("Empty Feed") {
    EmptyFeedView()
}
