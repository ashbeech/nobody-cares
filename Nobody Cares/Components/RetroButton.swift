//
//  RetroButton.swift
//  Nobody Cares
//
//  Retro system button styles — primary, secondary, disabled
//  No rounded corners. Hard pixel shadows. Instant press state.
//

import SwiftUI

// MARK: - Button Styles

enum RetroButtonVariant {
    case primary
    case secondary
}

struct RetroButtonStyle: ButtonStyle {
    let variant: RetroButtonVariant
    let isEnabled: Bool

    init(variant: RetroButtonVariant = .primary, isEnabled: Bool = true) {
        self.variant = variant
        self.isEnabled = isEnabled
    }

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && isEnabled

        configuration.label
            .font(NCFont.buttonLabel)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, NCMetrics.buttonPaddingH)
            .padding(.vertical, NCMetrics.buttonPaddingV)
            .foregroundColor(foregroundColor)
            .background(backgroundColor)
            .overlay(
                Rectangle()
                    .stroke(borderColor, lineWidth: NCMetrics.borderWidth)
            )
            .shadow(
                color: shadowColor,
                radius: 0,
                x: isPressed ? 1 : shadowX,
                y: isPressed ? 1 : shadowY
            )
            .offset(
                x: isPressed ? shadowX - 1 : 0,
                y: isPressed ? shadowY - 1 : 0
            )
            .opacity(isEnabled ? 1.0 : 0.5)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return NCColor.inkSecondary }
        switch variant {
        case .primary:   return NCColor.accentYellow
        case .secondary: return NCColor.ink
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else { return NCColor.dither }
        switch variant {
        case .primary:   return NCColor.ink
        case .secondary: return NCColor.background
        }
    }

    private var borderColor: Color {
        isEnabled ? NCColor.ink : NCColor.inkSecondary
    }

    private var shadowColor: Color {
        guard isEnabled else { return .clear }
        switch variant {
        case .primary:   return Color(hex: 0x1A1A1A)   // Near-black — matches dark fill
        case .secondary: return NCColor.shadow          // Subtle — matches body text shadow
        }
    }

    private var shadowX: CGFloat {
        variant == .primary ? NCMetrics.largeShadowOffset : NCMetrics.shadowOffset
    }

    private var shadowY: CGFloat {
        variant == .primary ? NCMetrics.largeShadowOffset : NCMetrics.shadowOffset
    }
}

// MARK: - Convenience

extension View {
    func retroButtonStyle(
        _ variant: RetroButtonVariant = .primary,
        isEnabled: Bool = true
    ) -> some View {
        self.buttonStyle(RetroButtonStyle(variant: variant, isEnabled: isEnabled))
    }
}

// MARK: - Premade Button

struct RetroButton: View {
    let title: String
    let variant: RetroButtonVariant
    var isEnabled: Bool = true
    var trailingIcon: PixelIconType? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let icon = trailingIcon {
                    PixelIcon(
                        type: icon,
                        size: 14,
                        color: variant == .primary ? NCColor.accentYellow : NCColor.ink
                    )
                }
            }
        }
        .retroButtonStyle(variant, isEnabled: isEnabled)
        .disabled(!isEnabled)
    }
}

#Preview("Retro Buttons") {
    VStack(spacing: 24) {
        RetroButton(title: "MAKE CONTENT", variant: .primary) {}
        RetroButton(title: "REFRESH", variant: .secondary) {}
        RetroButton(title: "DISABLED", variant: .primary, isEnabled: false) {}
        RetroButton(title: "CANCEL", variant: .secondary) {}
    }
    .padding(32)
    .background(NCColor.background)
}
