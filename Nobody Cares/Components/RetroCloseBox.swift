//
//  RetroCloseBox.swift
//  Nobody Cares
//
//  Classic Macintosh close box — empty square that draws an animated
//  'x' inside on tap before firing the close action, just like
//  System 7 did.
//

import SwiftUI

// MARK: - Close Box

struct RetroCloseBox: View {
    let action: () -> Void

    @State private var xProgress: CGFloat = 0
    @State private var isActivated = false

    var body: some View {
        ZStack {
            // Box outline
            Rectangle()
                .stroke(NCColor.ink, lineWidth: 1.5)
                .frame(
                    width: NCMetrics.closeBoxSize,
                    height: NCMetrics.closeBoxSize
                )
                .background(NCColor.background)

            // Animated X mark — draws itself on tap
            CloseXShape()
                .trim(from: 0, to: xProgress)
                .stroke(
                    NCColor.ink,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .square)
                )
                .frame(
                    width: NCMetrics.closeBoxSize - 3,
                    height: NCMetrics.closeBoxSize - 3
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isActivated else { return }
            isActivated = true

            // Draw the X
            withAnimation(.easeIn(duration: 0.12)) {
                xProgress = 1.0
            }

            // Fire close after the X is visible
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                action()
            }

            // Reset in case the view isn't torn down
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.08)) {
                    xProgress = 0
                }
                isActivated = false
            }
        }
    }
}

// MARK: - X Shape

/// Two diagonal strokes forming a cross — drawn progressively via `trim`.
private struct CloseXShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // First stroke: top-left → bottom-right
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        // Second stroke: top-right → bottom-left
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

// MARK: - Preview

#Preview("Close Box") {
    HStack(spacing: 24) {
        RetroCloseBox { print("closed") }

        // In context: title bar mockup
        ZStack {
            DitherPatternView(style: .stripes)
            HStack {
                RetroCloseBox { print("closed") }
                    .padding(.leading, 6)
                Spacer()
            }
            Text("WINDOW")
                .font(NCFont.dialogTitle)
                .padding(.horizontal, 8)
                .background(NCColor.background)
        }
        .frame(width: 200, height: NCMetrics.titleBarHeight)
        .retroBorder()
    }
    .padding(32)
}
