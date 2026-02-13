//
//  LoadingFeedView.swift
//  Nobody Cares
//
//  Loading state — hourglass animation + "SEARCHING FOR LOCAL CONTENT..."
//

import SwiftUI

struct LoadingFeedView: View {
    var body: some View {
        VStack(spacing: 24) {
            HourglassLoader(size: 48, color: NCColor.ink)

            Text("SEARCHING FOR LOCAL CONTENT\u{2026}")
                .font(NCFont.body(16))
                .foregroundColor(NCColor.ink)
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

#Preview("Loading Feed") {
    LoadingFeedView()
}
