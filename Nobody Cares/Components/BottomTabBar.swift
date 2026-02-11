//
//  BottomTabBar.swift
//  Nobody Cares
//
//  Persistent bottom tab bar — Feed (eye) + Make (camera+).
//  52pt + safe area. 2px top border. Yellow progress bar above.
//

import SwiftUI

struct BottomTabBar: View {
    @Binding var selectedTab: AppTab
    var progress: Double = 0.0

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator bar — 2px yellow, fills left-to-right
            GeometryReader { geo in
                Rectangle()
                    .fill(NCColor.accentYellow)
                    .frame(
                        width: geo.size.width * CGFloat(progress),
                        height: NCMetrics.progressBarHeight
                    )
            }
            .frame(height: NCMetrics.progressBarHeight)
            .background(NCColor.background)

            // Top border
            Rectangle()
                .fill(NCColor.ink)
                .frame(height: NCMetrics.borderWidth)

            // Tab buttons
            HStack(spacing: 0) {
                tabButton(
                    tab: .feed,
                    icon: .eye,
                    label: "FEED"
                )

                tabButton(
                    tab: .create,
                    icon: .camera,
                    label: "MAKE"
                )
            }
            .frame(height: NCMetrics.bottomBarHeight)
            .background(NCColor.background)
        }
    }

    private func tabButton(tab: AppTab, icon: PixelIconType, label: String) -> some View {
        let isActive = selectedTab == tab

        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                PixelIcon(
                    type: icon,
                    size: NCMetrics.iconSize,
                    color: NCColor.ink,
                    filled: isActive
                )

                Text(label)
                    .font(NCFont.tabLabel)
                    .fontWeight(isActive ? .bold : .regular)
                    .foregroundColor(NCColor.ink)
                    .tracking(0.5)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Bottom Tab Bar") {
    VStack {
        Spacer()
        BottomTabBar(
            selectedTab: .constant(.feed),
            progress: 0.4
        )
    }
}
