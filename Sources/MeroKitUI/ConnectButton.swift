#if canImport(SwiftUI)
import MeroKit
import SwiftUI

/// The labels ``ConnectButton`` shows per state.
public struct ConnectButtonLabels: Equatable {
    public var connect: String
    public var connected: String
    public var reconnecting: String

    public init(
        connect: String = "Connect", connected: String = "Connected", reconnecting: String = "Reconnecting..."
    ) {
        self.connect = connect
        self.connected = connected
        self.reconnecting = reconnecting
    }
}

/// Connection status, and the way in and out: disconnected it opens
/// ``LoginView`` (or connects straight to `customNodeURL`); connected it is a
/// menu naming the account and node, with Log out; online-but-down it reads
/// "Reconnecting...". (== mero-react `ConnectButton`.)
///
/// Identifiers: `connectButton`, `connectedButton`, `reconnectingButton`,
/// `connectedAccount`, `connectLogout`.
@MainActor
public struct ConnectButton: View {
    @EnvironmentObject private var client: MeroClient
    @Environment(\.meroTheme) private var theme
    @State private var showLogin = false

    private let callbackScheme: String
    private let labels: ConnectButtonLabels
    private let logoOnly: Bool
    private let tabs: [LoginModalTab]
    private let customNodeURL: String?

    /// - Parameters:
    ///   - callbackScheme: the app's URL scheme (see ``LoginView``).
    ///   - cloud: offer the Cloud tab; `false` leaves the node dialog alone.
    ///   - customNodeURL: connect straight to this node, skipping the dialog
    ///     (mero-react's `ConnectionType.Custom`).
    ///   - logoOnly: the emblem alone; the label is still read to VoiceOver.
    public init(
        callbackScheme: String, labels: ConnectButtonLabels = ConnectButtonLabels(), logoOnly: Bool = false,
        cloud: Bool = true, customNodeURL: String? = nil
    ) {
        self.callbackScheme = callbackScheme
        self.labels = labels
        self.logoOnly = logoOnly
        self.tabs = cloud ? [.node, .cloud] : [.node]
        self.customNodeURL = customNodeURL
    }

    /// A bare connect label. (mero-react's `label="…"` shorthand.)
    public init(callbackScheme: String, label: String, cloud: Bool = true) {
        self.init(callbackScheme: callbackScheme, labels: ConnectButtonLabels(connect: label), cloud: cloud)
    }

    public var body: some View {
        Group {
            if client.isAuthenticated && !client.isOnline {
                face(labels.reconnecting, filled: false)
                    .opacity(0.6)
                    .accessibilityIdentifier("reconnectingButton")
            } else if client.isAuthenticated {
                connectedMenu
            } else {
                Button(action: connect) { face(labels.connect, filled: false) }
                    .buttonStyle(.plain)
                    .disabled(client.isLoading)
                    .accessibilityIdentifier("connectButton")
            }
        }
        .sheet(isPresented: loginPresented) {
            LoginView(callbackScheme: callbackScheme, tabs: tabs, initialTab: tabs[0])
                .environmentObject(client)
                .meroTheme(theme)
                .padding(.vertical, 24)
        }
    }

    /// Closes by itself once a sign-in lands.
    private var loginPresented: Binding<Bool> {
        Binding(get: { showLogin && !client.isAuthenticated }, set: { showLogin = $0 })
    }

    private var connectedMenu: some View {
        Menu {
            if client.isDelegated, let account = client.account {
                Text("Account \(Self.shortAccount(account))")
                    .accessibilityIdentifier("connectedAccount")
            }
            Text(client.nodeURL.isEmpty ? (client.isDelegated ? "no relay yet" : "") : client.nodeURL)
            if client.isDelegated, let note = client.cloudNote {
                Text(note)
            }
            Button(role: .destructive) {
                Task { await client.logout() }
            } label: {
                Text("Log out")
            }
            .accessibilityIdentifier("connectLogout")
        } label: {
            face(labels.connected, filled: true)
        }
        .accessibilityIdentifier("connectedButton")
    }

    private func face(_ label: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            CalimeroLogo(size: 18, color: filled ? theme.primaryText : theme.primary)
            if !logoOnly { Text(label).font(.subheadline.weight(.semibold)) }
        }
        .foregroundColor(filled ? theme.primaryText : theme.primary)
        .padding(.horizontal, logoOnly ? 11 : 14)
        .frame(minWidth: logoOnly ? 40 : nil, minHeight: 40)
        .background(RoundedRectangle(cornerRadius: theme.radius).fill(filled ? theme.primary : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.primary, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func connect() {
        if let customNodeURL {
            Task { await client.connectToNode(customNodeURL, callbackScheme: callbackScheme) }
        } else {
            showLogin = true
        }
    }

    /// `abcdef…123456` — enough of a 64-hex account id to recognise it.
    static func shortAccount(_ account: String) -> String {
        account.count > 14 ? "\(account.prefix(6))…\(account.suffix(6))" : account
    }
}
#endif
