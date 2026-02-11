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
    /// When true, the pattern slowly scrolls upward for a subtle "static" effect
    var animated: Bool = false

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                // Light dither repeats every 4px (step 2 × 2 rows), scroll at 6px/sec
                let offset = CGFloat(seconds.truncatingRemainder(dividingBy: 1000)) * 6
                canvas(yOffset: offset)
            }
        } else {
            canvas(yOffset: 0)
        }
    }

    private func canvas(yOffset: CGFloat) -> some View {
        Canvas { context, size in
            // Fill background
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(background)
            )

            let fg = foreground

            switch style {
            case .checkerboard:
                drawCheckerboard(context: context, size: size, color: fg, yOffset: yOffset)
            case .light:
                drawLightDither(context: context, size: size, color: fg, yOffset: yOffset)
            case .stripes:
                drawStripes(context: context, size: size, color: fg, yOffset: yOffset)
            }
        }
    }

    private func drawCheckerboard(context: GraphicsContext, size: CGSize, color: Color, yOffset: CGFloat) {
        let step: CGFloat = 2
        let period = step * 2
        let startY = -CGFloat(Int(yOffset) % Int(period))
        var y: CGFloat = startY
        var row = Int((yOffset) / step)
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

    private func drawLightDither(context: GraphicsContext, size: CGSize, color: Color, yOffset: CGFloat) {
        let step: CGFloat = 2
        let period = step * 4 // pattern repeats every 4 rows of step-height
        let startY = -CGFloat(Int(yOffset) % Int(period))
        var y: CGFloat = startY
        var row = Int(yOffset / step)
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

    private func drawStripes(context: GraphicsContext, size: CGSize, color: Color, yOffset: CGFloat) {
        let period: CGFloat = 2
        let startY = -CGFloat(Int(yOffset) % Int(period))
        var y: CGFloat = startY
        var row = Int(yOffset)
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
