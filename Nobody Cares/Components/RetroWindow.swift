//
//  RetroWindow.swift
//  Nobody Cares
//
//  Retro Macintosh System 1-7 window chrome.
//  Striped title bar, close box, 2px border, hard shadow.
//

import SwiftUI

struct RetroWindow<Content: View>: View {
    let title: String
    var icon: PixelIconType? = nil
    var showCloseBox: Bool = false
    var onClose: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            titleBar

            // Content area
            content()
                .frame(maxWidth: .infinity)
                .background(NCColor.background)
        }
        .overlay(
            Rectangle()
                .stroke(NCColor.ink, lineWidth: NCMetrics.borderWidth)
        )
        .hardShadow(x: NCMetrics.largeShadowOffset, y: NCMetrics.largeShadowOffset)
        .background(NCColor.background)
    }

    private var titleBar: some View {
        ZStack {
            // Striped background
            DitherPatternView(style: .stripes, foreground: NCColor.ink, background: NCColor.background)

            // Title text with background knockout
            HStack(spacing: 6) {
                if let icon = icon {
                    PixelIcon(type: icon, size: 14)
                }
                Text(title)
                    .font(NCFont.dialogTitle)
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundColor(NCColor.ink)
            }
            .padding(.horizontal, 8)
            .background(NCColor.background)

            // Close box
            if showCloseBox {
                HStack {
                    Button(action: { onClose?() }) {
                        Rectangle()
                            .stroke(NCColor.ink, lineWidth: 1.5)
                            .frame(
                                width: NCMetrics.closeBoxSize,
                                height: NCMetrics.closeBoxSize
                            )
                            .background(NCColor.background)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                    Spacer()
                }
            }
        }
        .frame(height: NCMetrics.titleBarHeight)
        .frame(maxWidth: .infinity)
        .overlay(
            Rectangle()
                .frame(height: NCMetrics.borderWidth)
                .foregroundColor(NCColor.ink),
            alignment: .bottom
        )
    }
}

#Preview("Retro Window") {
    RetroWindow(title: "ALERT", icon: .caution, showCloseBox: true) {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOBODY CARES:")
                .font(NCFont.display(16))
                .textCase(.uppercase)

            Text("This area has been assessed for interest. None was found.")
                .font(NCFont.dialogBody)

            HStack {
                Spacer()
                RetroButton(title: "OK", variant: .primary) {}
            }
        }
        .padding(NCMetrics.dialogPadding)
    }
    .padding(32)
}
