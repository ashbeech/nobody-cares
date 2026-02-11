//
//  RetroDialog.swift
//  Nobody Cares
//
//  Full-screen modal dialog — retro system alert style.
//  Dithered background, centered RetroWindow, action buttons.
//

import SwiftUI

struct RetroDialog: View {
    let title: String
    var icon: PixelIconType? = .caution
    let headline: String
    var body_text: String? = nil
    var primaryAction: DialogAction? = nil
    var secondaryAction: DialogAction? = nil
    var onDismiss: (() -> Void)? = nil

    struct DialogAction {
        let title: String
        let action: () -> Void
    }

    var body: some View {
        ZStack {
            // Dither background
            NCColor.background
                .ditherOverlay(style: .light, opacity: 0.08)
                .ignoresSafeArea()

            // Dialog window
            RetroWindow(
                title: title,
                icon: icon,
                showCloseBox: onDismiss != nil,
                onClose: onDismiss
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    // Headline
                    Text(headline)
                        .font(NCFont.display(16))
                        .foregroundColor(NCColor.ink)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    // Body text
                    if let bodyText = body_text {
                        Text(bodyText)
                            .font(NCFont.dialogBody)
                            .foregroundColor(NCColor.ink)
                            .lineSpacing(4)
                    }

                    // Action buttons
                    if primaryAction != nil || secondaryAction != nil {
                        HStack(spacing: 12) {
                            Spacer()
                            if let secondary = secondaryAction {
                                RetroButton(
                                    title: secondary.title,
                                    variant: .secondary,
                                    action: secondary.action
                                )
                            }
                            if let primary = primaryAction {
                                RetroButton(
                                    title: primary.title,
                                    variant: .primary,
                                    action: primary.action
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(NCMetrics.dialogPadding)
            }
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - View Modifier for Dialog Presentation

struct RetroDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let dialog: () -> RetroDialog

    func body(content: Content) -> some View {
        ZStack {
            content

            if isPresented {
                dialog()
                    .transition(.move(edge: .bottom))
                    .zIndex(100)
            }
        }
        .animation(.linear(duration: 0.2), value: isPresented)
    }
}

extension View {
    func retroDialog(
        isPresented: Binding<Bool>,
        @ViewBuilder dialog: @escaping () -> RetroDialog
    ) -> some View {
        modifier(RetroDialogModifier(isPresented: isPresented, dialog: dialog))
    }
}

#Preview("Retro Dialog") {
    RetroDialog(
        title: "WARNING",
        icon: .caution,
        headline: "NO MORE LOCAL CONTENT",
        body_text: "DOPAMINE DROP IMMINENT.\n\nPlease vacate the area or produce more content.",
        primaryAction: .init(title: "MAKE CONTENT", action: {}),
        secondaryAction: .init(title: "REFRESH", action: {}),
        onDismiss: {}
    )
}
