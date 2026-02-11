//
//  Theme.swift
//  Nobody Cares
//
//  Design system tokens — retro Macintosh aesthetic
//

import SwiftUI
import UIKit

// MARK: - Color Tokens

enum NCColor {
    static let background   = Color.white                   // #FFFFFF
    static let surface      = Color(hex: 0xF5F5F5)         // #F5F5F5
    static let ink          = Color.black                   // #000000
    static let inkSecondary = Color(hex: 0x666666)          // #666666
    static let dither       = Color(hex: 0xC0C0C0)         // #C0C0C0
    static let accentYellow = Color(hex: 0xE8FF00)          // #E8FF00
    static let accentPink   = Color(hex: 0xFF1493)          // #FF1493
    static let accentTeal   = Color(hex: 0x008080)          // #008080
    static let error        = Color.red                     // #FF0000
    static let shadow       = Color(hex: 0xDCDCDC)          // #DCDCDC — subtle shadow for light backgrounds
}

// MARK: - Typography

enum NCFont {
    /// The custom pixel font name. Falls back to system monospaced if not bundled.
    private static let customFontName = "DepartureMono-Regular"

    /// Check if the custom font is available at runtime
    private static var hasCustomFont: Bool {
        UIFont(name: customFontName, size: 14) != nil
    }

    /// Core font provider — tries Departure Mono, falls back to system monospaced
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if hasCustomFont {
            let font = Font.custom(customFontName, size: size)
            return weight == .bold ? font.bold() : font
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    // --- Named styles ---

    /// Display / Headers — bold, uppercase context
    static func display(_ size: CGFloat = 24) -> Font {
        font(size: size, weight: .bold)
    }

    /// Body text
    static func body(_ size: CGFloat = 14) -> Font {
        font(size: size, weight: .regular)
    }

    /// Dialog / system text
    static func system(_ size: CGFloat = 13) -> Font {
        font(size: size, weight: .regular)
    }

    // --- Preset sizes ---

    static let heading     = display(24)
    static let subheading  = display(18)
    static let bodyDefault = body(14)
    static let caption     = body(12)
    static let tabLabel    = font(size: 10, weight: .regular)
    static let dialogTitle = display(14)
    static let dialogBody  = system(13)
    static let buttonLabel = font(size: 14, weight: .bold)
}

// MARK: - Spacing & Dimensions

enum NCMetrics {
    static let borderWidth: CGFloat     = 2
    static let shadowOffset: CGFloat    = 2
    static let largeShadowOffset: CGFloat = 3
    static let iconSize: CGFloat        = 24
    static let smallIconSize: CGFloat   = 16
    static let topBarHeight: CGFloat    = 56
    static let bottomBarHeight: CGFloat = 52
    static let progressBarHeight: CGFloat = 2
    static let buttonPaddingH: CGFloat  = 16
    static let buttonPaddingV: CGFloat  = 10
    static let dialogPadding: CGFloat   = 16
    static let contentPadding: CGFloat  = 16
    static let titleBarHeight: CGFloat  = 24
    static let closeBoxSize: CGFloat    = 12
    static let shutterSize: CGFloat     = 72
    static let shutterOuterSize: CGFloat = 80
}

// MARK: - View Modifiers

/// Adds a hard pixel shadow (no blur)
struct HardShadow: ViewModifier {
    var color: Color = NCColor.shadow
    var x: CGFloat = 2
    var y: CGFloat = 2

    func body(content: Content) -> some View {
        content
            .shadow(color: color, radius: 0, x: x, y: y)
    }
}

/// Retro bordered container — 2px solid black, no rounded corners
struct RetroBorder: ViewModifier {
    var color: Color = NCColor.ink
    var width: CGFloat = NCMetrics.borderWidth

    func body(content: Content) -> some View {
        content
            .overlay(
                Rectangle()
                    .stroke(color, lineWidth: width)
            )
    }
}

extension View {
    func hardShadow(
        color: Color = NCColor.shadow,
        x: CGFloat = NCMetrics.shadowOffset,
        y: CGFloat = NCMetrics.shadowOffset
    ) -> some View {
        modifier(HardShadow(color: color, x: x, y: y))
    }

    func retroBorder(
        color: Color = NCColor.ink,
        width: CGFloat = NCMetrics.borderWidth
    ) -> some View {
        modifier(RetroBorder(color: color, width: width))
    }
}

// MARK: - Color Hex Initializer

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
