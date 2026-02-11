//
//  BannedView.swift
//  Nobody Cares
//
//  Shown when a user's trust_score hits 0 and they are permanently banned.
//  "YOUR ACCESS HAS BEEN REVOKED. This decision is final. Nobody cares."
//

import SwiftUI

struct BannedView: View {
    var body: some View {
        ZStack {
            NCColor.ink
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Big lock icon
                PixelIcon(type: .lock, size: 64, color: NCColor.error, filled: true)

                RetroWindow(title: "ACCESS REVOKED", icon: .caution) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("YOUR ACCESS HAS BEEN REVOKED")
                            .font(NCFont.display(16))
                            .foregroundColor(NCColor.ink)
                            .tracking(0.5)

                        Text("Your account has been permanently suspended due to repeated violations of usage policies.")
                            .font(NCFont.dialogBody)
                            .foregroundColor(NCColor.ink)
                            .lineSpacing(4)

                        Text("This decision is final.")
                            .font(NCFont.display(14))
                            .foregroundColor(NCColor.ink)

                        Text("Nobody cares.")
                            .font(NCFont.dialogBody)
                            .foregroundColor(NCColor.inkSecondary)
                            .italic()
                    }
                    .padding(NCMetrics.dialogPadding)
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
    }
}

#Preview("Banned") {
    BannedView()
}
