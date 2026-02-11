//
//  DitherPatternView.swift
//  Nobody Cares
//
//  1-bit dither patterns — classic Macintosh style
//

import SwiftUI

// MARK: - Dither Pattern Types

enum DitherStyle {
    /// 50% — alternating black/white pixels (checkerboard)
    case checkerboard
    /// 25% — lighter dither, every other pixel in every other row
    case light
    /// Horizontal stripes — 1px alternating lines (for title bars)
    case stripes
}

// MARK: - Dither Pattern View

struct DitherPatternView: View {
    let style: DitherStyle
    var foreground: Color = NCColor.ink
    var background: Color = NCColor.background

    var body: some View {
        Canvas { context, size in
            // Fill background
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(background)
            )

            let fg = foreground

            switch style {
            case .checkerboard:
                drawCheckerboard(context: context, size: size, color: fg)
            case .light:
                drawLightDither(context: context, size: size, color: fg)
            case .stripes:
                drawStripes(context: context, size: size, color: fg)
            }
        }
    }

    private func drawCheckerboard(context: GraphicsContext, size: CGSize, color: Color) {
        let step: CGFloat = 2
        var y: CGFloat = 0
        var row = 0
        while y < size.height {
            var x: CGFloat = (row % 2 == 0) ? 0 : step
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: y, width: step, height: step)),
                    with: .color(color)
                )
                x += step * 2
            }
            y += step
            row += 1
        }
    }

    private func drawLightDither(context: GraphicsContext, size: CGSize, color: Color) {
        let step: CGFloat = 2
        var y: CGFloat = 0
        var row = 0
        while y < size.height {
            if row % 2 == 0 {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(
                        Path(CGRect(x: x, y: y, width: step, height: step)),
                        with: .color(color)
                    )
                    x += step * 4
                }
            }
            y += step
            row += 1
        }
    }

    private func drawStripes(context: GraphicsContext, size: CGSize, color: Color) {
        var y: CGFloat = 0
        var row = 0
        while y < size.height {
            if row % 2 == 0 {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(color)
                )
            }
            y += 1
            row += 1
        }
    }
}

// MARK: - Convenience Modifiers

extension View {
    /// Overlay a dither pattern on this view
    func ditherOverlay(
        style: DitherStyle = .checkerboard,
        opacity: Double = 0.15
    ) -> some View {
        self.overlay(
            DitherPatternView(style: style)
                .opacity(opacity)
                .allowsHitTesting(false)
        )
    }
}

#Preview("Dither Patterns") {
    VStack(spacing: 20) {
        DitherPatternView(style: .checkerboard)
            .frame(height: 60)
            .retroBorder()

        DitherPatternView(style: .light)
            .frame(height: 60)
            .retroBorder()

        DitherPatternView(style: .stripes)
            .frame(height: 60)
            .retroBorder()
    }
    .padding()
}
