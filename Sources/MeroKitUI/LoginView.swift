#if canImport(SwiftUI)
import SwiftUI

/// Cloud sign-in, bound to ``MeroClient``: one "Continue with Calimero"
/// button that opens the Calimero wallet in the system auth sheet — the same
/// shape as "Sign in with Google". There is no node URL and no password; the
/// person approves this device with their passkey on the wallet's own page.
///
/// Accessibility identifiers for UI tests: `loginTitle`, `loginError`,
/// `cloudSignInButton` (the button), and `loginButton` (the sign-in panel
/// containing it, kept so existing tests can still find the login surface).
public struct LoginView: View {
    @EnvironmentObject private var client: MeroClient

    private let callback: CloudCallback

    /// - Parameter callbackScheme: the app's URL scheme the wallet returns to,
    ///   e.g. `"mero-sample"` → `mero-sample://enrol`.
    public init(callbackScheme: String) {
        self.callback = .scheme(callbackScheme)
    }

    /// Return through a verified https callback (Universal Link) instead.
    public init(callback: CloudCallback) {
        self.callback = callback
    }

    public var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            Image(systemName: "person.badge.key")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(Self.accentInk)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Self.accentSoft))
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Sign in to Calimero")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("loginTitle")

                Text(
                    "You'll approve this device with your passkey on the Calimero wallet, then come straight back. "
                        + "Your account key never leaves the wallet; this app only receives a certificate for its own "
                        + "device key."
                )
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                if let error = client.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundColor(Self.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Self.dangerSoft))
                        .accessibilityIdentifier("loginError")
                }

                Button {
                    Task { await client.signInWithCloud(callback: callback) }
                } label: {
                    HStack(spacing: 8) {
                        if client.isLoading {
                            ProgressView().tint(Self.ink)
                        } else {
                            Image(systemName: "key.fill").font(.system(size: 14, weight: .semibold))
                        }
                        Text("Continue with Calimero").font(.body.weight(.semibold))
                    }
                    .foregroundColor(Self.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Self.lime))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.06), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(client.isLoading)
                .accessibilityIdentifier("cloudSignInButton")

                Text("Uses the system sign-in sheet. Nothing to paste in.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("loginButton")

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 480)
    }

    // Calimero tokens (light).
    static let ink = Color(red: 0x13 / 255, green: 0x12 / 255, blue: 0x15 / 255)
    static let lime = Color(red: 0xA5 / 255, green: 0xFF / 255, blue: 0x11 / 255)
    static let accentInk = Color(red: 0x4A / 255, green: 0x73 / 255, blue: 0x00 / 255)
    static let accentSoft = Color(red: 0xF0 / 255, green: 0xFF / 255, blue: 0xD6 / 255)
    static let danger = Color(red: 0xC6 / 255, green: 0x28 / 255, blue: 0x28 / 255)
    static let dangerSoft = Color(red: 0xFD / 255, green: 0xEC / 255, blue: 0xEC / 255)
}
#endif
