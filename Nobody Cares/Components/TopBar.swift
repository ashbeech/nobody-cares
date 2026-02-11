//
//  TopBar.swift
//  Nobody Cares
//
//  Persistent top bar — logo wordmark left, settings gear right.
//  56pt tall, white background, 2px bottom border.
//

import SwiftUI

struct TopBar: View {
    var onSettingsTapped: () -> Void = {}

    var body: some View {
        HStack {
            // Logo wordmark
            Text("NOBODY CARES")
                .font(NCFont.display(16))
                .foregroundColor(NCColor.ink)
                .tracking(1.5)

            Spacer()

            // Settings gear
            Button(action: onSettingsTapped) {
                PixelIcon(type: .gear, size: NCMetrics.iconSize)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NCMetrics.contentPadding)
        .frame(height: NCMetrics.topBarHeight)
        .frame(maxWidth: .infinity)
        .background(NCColor.background)
        .overlay(
            Rectangle()
                .frame(height: NCMetrics.borderWidth)
                .foregroundColor(NCColor.ink),
            alignment: .bottom
        )
    }
}

#Preview("Top Bar") {
    VStack {
        TopBar()
        Spacer()
    }
}
