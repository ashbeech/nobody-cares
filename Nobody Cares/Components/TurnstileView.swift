//
//  TurnstileView.swift
//  Nobody Cares
//
//  Cloudflare Turnstile CAPTCHA — renders in a WKWebView.
//  Mostly invisible for legitimate users. Shows a checkbox challenge
//  only when Cloudflare suspects abuse.
//
//  Used in two contexts:
//  1. On account creation (always, usually invisible)
//  2. On rate limit escalation (visible challenge inside retro dialog)
//

import SwiftUI
import WebKit

// MARK: - Turnstile Token Provider

@Observable
final class TurnstileTokenProvider {
    var token: String?
    var isLoading = false
    var error: String?

    func reset() {
        token = nil
        isLoading = false
        error = nil
    }
}

// MARK: - Turnstile WebView (UIViewRepresentable)

struct TurnstileWebView: UIViewRepresentable {
    let siteKey: String
    let onToken: (String) -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false

        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "turnstile")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator

        let html = turnstileHTML(siteKey: siteKey)
        webView.loadHTMLString(html, baseURL: URL(string: "https://challenges.cloudflare.com"))

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onError: onError)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onToken: (String) -> Void
        let onError: (String) -> Void

        init(onToken: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onToken = onToken
            self.onError = onError
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: String] else { return }

            if let token = body["token"] {
                onToken(token)
            } else if let error = body["error"] {
                onError(error)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError("Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - HTML Template

    private func turnstileHTML(siteKey: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    margin: 0; padding: 16px;
                    display: flex; justify-content: center; align-items: center;
                    min-height: 80px;
                    background: transparent;
                    font-family: monospace;
                }
            </style>
            <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
        </head>
        <body>
            <div id="turnstile-widget"></div>
            <script>
                function onTurnstileLoad() {
                    turnstile.render('#turnstile-widget', {
                        sitekey: '\(siteKey)',
                        callback: function(token) {
                            window.webkit.messageHandlers.turnstile.postMessage({token: token});
                        },
                        'error-callback': function(error) {
                            window.webkit.messageHandlers.turnstile.postMessage({error: String(error)});
                        },
                        'expired-callback': function() {
                            window.webkit.messageHandlers.turnstile.postMessage({error: 'expired'});
                        },
                        theme: 'light',
                        appearance: 'interaction-only'
                    });
                }
                // Wait for Turnstile script to load
                if (typeof turnstile !== 'undefined') {
                    onTurnstileLoad();
                } else {
                    document.querySelector('script[src*="turnstile"]').addEventListener('load', onTurnstileLoad);
                }
            </script>
        </body>
        </html>
        """
    }
}

// MARK: - Captcha Challenge Dialog

/// Full retro-styled CAPTCHA dialog shown when human verification is required.
/// Used for rate limit escalation (abuse-3) and forced verification scenarios.
struct CaptchaChallengeView: View {
    let onToken: (String) -> Void
    let onDismiss: (() -> Void)?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ZStack {
            NCColor.background
                .ditherOverlay(style: .light, opacity: 0.08)
                .ignoresSafeArea()

            RetroWindow(
                title: "VERIFICATION",
                icon: .caution,
                showCloseBox: onDismiss != nil,
                onClose: onDismiss
            ) {
                VStack(spacing: 16) {
                    Text("HUMAN VERIFICATION REQUIRED")
                        .font(NCFont.display(14))
                        .foregroundColor(NCColor.ink)
                        .tracking(0.5)

                    Text("Prove you are not a machine.")
                        .font(NCFont.dialogBody)
                        .foregroundColor(NCColor.ink)

                    // Turnstile widget
                    TurnstileWebView(
                        siteKey: Secrets.turnstileSiteKey,
                        onToken: { token in
                            isLoading = false
                            onToken(token)
                        },
                        onError: { err in
                            isLoading = false
                            error = err
                        }
                    )
                    .frame(height: 80)
                    .retroBorder()

                    if isLoading {
                        HStack(spacing: 8) {
                            PixelIcon(type: .hourglass, size: 16)
                            Text("VERIFYING...")
                                .font(NCFont.caption)
                                .foregroundColor(NCColor.inkSecondary)
                        }
                    }

                    if let error {
                        Text("VERIFICATION FAILED: \(error.uppercased())")
                            .font(NCFont.caption)
                            .foregroundColor(NCColor.error)
                    }
                }
                .padding(NCMetrics.dialogPadding)
            }
            .padding(.horizontal, 32)
        }
    }
}

#Preview("Captcha Challenge") {
    CaptchaChallengeView(
        onToken: { _ in },
        onDismiss: {}
    )
}
