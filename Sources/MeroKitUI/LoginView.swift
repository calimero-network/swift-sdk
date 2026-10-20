#if canImport(SwiftUI)
import MeroKit
import SwiftUI

/// Sign-in, bound to ``MeroClient``. (== mero-react `LoginModal`.)
///
/// - **Cloud**: one "Continue with Calimero Cloud" button that opens the
///   Calimero wallet in the system auth sheet, the same shape as "Sign in with
///   Google".
/// - **Node**: the local nodes discovery found and a URL field. By default
///   Connect opens the node's own login page; with `nodeSignIn: .password` it
///   asks for the node's admin username and password instead.
///
/// `mode` picks which are offered: ``LoginMode/cloudAndNode`` (Cloud, with a
/// small "Manually enter node URL" link under it), ``LoginMode/cloudOnly`` or
/// ``LoginMode/nodeOnly``. Colours, radii and type come from the environment's
/// ``MeroTheme``; every word, the logo and its tile from ``LoginBranding``.
///
/// Accessibility identifiers for UI tests: `loginTitle`, `loginError`,
/// `cloudSignInButton` (the button), `loginButton` (the Cloud panel),
/// `manualNode` / `useCloud` (the link between them), and on the node side
/// `nodeDiscovering`, `nodeOption-<host:port>`, `nodeOption-custom`,
/// `nodeUrlInput`, `nodeUserInput`, `nodePasswordInput`, `rescanButton` and
/// `nodeConnectButton`.
@MainActor
public struct LoginView: View {
    @EnvironmentObject private var client: MeroClient
    @Environment(\.meroTheme) private var theme

    private let callback: CloudCallback
    private let nodeCallback: CloudCallback
    private let mode: LoginMode
    private let nodeSignIn: NodeSignInMethod
    private let branding: LoginBranding
    @State private var tab: LoginModalTab

    /// - Parameters:
    ///   - callbackScheme: the app's URL scheme the wallet (`<scheme>://enrol`)
    ///     and a node's login page (`<scheme>://auth`) return to.
    ///   - mode: which ways to sign in to offer.
    ///   - nodeSignIn: how a node sign-in authenticates.
    ///   - branding: titles, button label and logo.
    public init(
        callbackScheme: String, mode: LoginMode = .cloudAndNode, nodeSignIn: NodeSignInMethod = .loginPage,
        branding: LoginBranding = LoginBranding()
    ) {
        self.init(
            callback: .scheme(callbackScheme), nodeCallback: .scheme(callbackScheme, path: "auth"), mode: mode,
            nodeSignIn: nodeSignIn, branding: branding)
    }

    /// Return through `callback` (an https Universal Link, say), and from a
    /// node's login page through `nodeCallback` (the same host's `/auth` by default).
    public init(
        callback: CloudCallback, nodeCallback: CloudCallback? = nil, mode: LoginMode = .cloudAndNode,
        nodeSignIn: NodeSignInMethod = .loginPage, branding: LoginBranding = LoginBranding()
    ) {
        self.callback = callback
        self.nodeCallback = nodeCallback ?? Self.authCallback(for: callback)
        self.mode = mode
        self.nodeSignIn = nodeSignIn
        self.branding = branding
        _tab = State(initialValue: mode.tabs[0])
    }

    /// The `tabs:` form, kept for existing callers: the tabs offered become a
    /// ``LoginMode`` and `initialTab` the side it opens on.
    public init(callbackScheme: String, tabs: [LoginModalTab], initialTab: LoginModalTab = .cloud) {
        self.init(
            callback: .scheme(callbackScheme), nodeCallback: .scheme(callbackScheme, path: "auth"), tabs: tabs,
            initialTab: initialTab)
    }

    public init(
        callback: CloudCallback, nodeCallback: CloudCallback? = nil, tabs: [LoginModalTab],
        initialTab: LoginModalTab = .cloud
    ) {
        let mode = LoginMode(tabs: tabs)
        self.init(callback: callback, nodeCallback: nodeCallback, mode: mode)
        _tab = State(initialValue: mode.tabs.contains(initialTab) ? initialTab : mode.tabs[0])
    }

    static func authCallback(for callback: CloudCallback) -> CloudCallback {
        switch callback {
        case .scheme(let scheme, _): return .scheme(scheme, path: "auth")
        case .https(let host, _): return .https(host: host, path: "/auth")
        }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()
            if theme.showsGlow {
                RadialGradient(
                    colors: [theme.primary.opacity(0.35), theme.primary.opacity(0.08), .clear],
                    center: .top, startRadius: 0, endRadius: 420
                )
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
            ScrollView {
                VStack(spacing: 26) {
                    hero.padding(.top, tab == .node ? 36 : 88)
                    VStack(spacing: 14) {
                        if let error = client.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundColor(theme.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: theme.radius).fill(theme.error.opacity(0.1)))
                                .accessibilityIdentifier("loginError")
                        }
                        switch tab {
                        case .cloud:
                            AccountSignInPanel(
                                note: client.cloudNote, isWorking: client.isLoading, buttonTitle: branding.cloudButton,
                                hint: branding.cloudHint, customWalletNote: branding.customWalletNote
                            ) {
                                Task { await client.signInWithCloud(callback: callback) }
                            }
                        case .node:
                            NodeLoginPanel(callback: nodeCallback, method: nodeSignIn, strings: branding.node)
                                .padding(18)
                                .background(RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.surface))
                                .overlay(RoundedRectangle(cornerRadius: theme.cardRadius).stroke(theme.border))
                        }
                        if mode == .cloudAndNode {
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    tab = tab == .cloud ? .node : .cloud
                                    client.clearError()
                                }
                            } label: {
                                Text(tab == .cloud ? branding.manualNodeLink : branding.useCloudLink)
                                    .font(.footnote.weight(.medium))
                                    .underline(tab == .cloud, color: theme.textTertiary.opacity(0.5))
                                    .foregroundColor(theme.textSecondary)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(tab == .cloud ? "manualNode" : "useCloud")
                        }
                    }
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var tileFill: Color { branding.logoTileBackground ?? theme.primary }

    private var hero: some View {
        VStack(spacing: 18) {
            Group {
                if let logo = branding.logo {
                    logo.resizable().scaledToFit().padding(16)
                } else {
                    CalimeroLogo(size: 40, color: theme.primaryText)
                }
            }
            .frame(width: branding.logoTileSize, height: branding.logoTileSize)
            .background(RoundedRectangle(cornerRadius: branding.logoTileCornerRadius).fill(tileFill))
            .overlay(
                RoundedRectangle(cornerRadius: branding.logoTileCornerRadius).stroke(
                    Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: branding.logoTileShadow ? tileFill.opacity(0.35) : .clear, radius: 18, y: 8)
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(tab == .node ? branding.nodeTitle : branding.cloudTitle)
                    .font(.system(.largeTitle, design: theme.titleDesign).weight(.bold))
                    .foregroundColor(theme.text)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("loginTitle")
                Text(tab == .node ? branding.nodeSubtitle : branding.cloudSubtitle)
                    .font(.callout)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The Cloud side: one button to the wallet, and what the last enrolment had
/// to say. Presentational; the flow is ``MeroClient/signInWithCloud(callback:)``
/// (or ``AccountEnrolment``). (== mero-react `AccountSignInPanel`.)
///
/// Identifiers: `loginButton` (the panel), `cloudSignInButton`, `accountNote`.
@MainActor
public struct AccountSignInPanel: View {
    @Environment(\.meroTheme) private var theme

    public var note: String?
    public var isWorking: Bool
    /// Shown when enrolment goes to a wallet other than the hosted one.
    public var customWalletURL: URL?
    public var buttonTitle: String
    /// The line under the button; `nil` hides it.
    public var hint: String?
    /// The note for ``customWalletURL``.
    public var customWalletNote: @Sendable (URL) -> String
    public var onEnrol: () -> Void

    public init(
        note: String? = nil, isWorking: Bool = false, customWalletURL: URL? = nil,
        buttonTitle: String = "Continue with Calimero Cloud",
        hint: String? = "Opens the Calimero wallet to approve this device",
        customWalletNote: @escaping @Sendable (URL) -> String = LoginBranding.defaultCustomWalletNote,
        onEnrol: @escaping () -> Void
    ) {
        self.note = note
        self.isWorking = isWorking
        self.customWalletURL = customWalletURL
        self.buttonTitle = buttonTitle
        self.hint = hint
        self.customWalletNote = customWalletNote
        self.onEnrol = onEnrol
    }

    public var body: some View {
        VStack(spacing: 10) {
            Button(action: onEnrol) {
                HStack(spacing: 10) {
                    if isWorking {
                        ProgressView().tint(theme.primaryText)
                    } else {
                        Image(systemName: "cloud.fill").font(.callout)
                    }
                    Text(buttonTitle).font(.body.weight(.semibold))
                }
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: theme.controlHeight)
                .background(RoundedRectangle(cornerRadius: theme.radius).fill(theme.primary))
                .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(Color.black.opacity(0.06), lineWidth: 1))
                .opacity(isWorking ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityIdentifier("cloudSignInButton")

            if let hint {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.key").font(.caption)
                    Text(hint)
                }
                .font(.caption)
                .foregroundColor(theme.textTertiary)
            }

            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("accountNote")
            }
            if let customWalletURL {
                Text(customWalletNote(customWalletURL))
                    .font(.caption2)
                    .foregroundColor(theme.textTertiary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loginButton")
    }
}

/// The node side: discovered local nodes and a URL field. Connect opens the
/// chosen node's login page, or with ``NodeSignInMethod/password`` signs in
/// with the node's admin username and password. (== mero-react
/// `LoginModal`'s node section.)
@MainActor
public struct NodeLoginPanel: View {
    @EnvironmentObject private var client: MeroClient
    @Environment(\.meroTheme) private var theme
    @StateObject private var model: NodeLoginModel
    @State private var username = ""
    @State private var password = ""
    private let callback: CloudCallback
    private let method: NodeSignInMethod
    private let strings: NodeLoginStrings

    public init(
        callback: CloudCallback, method: NodeSignInMethod = .loginPage,
        ports: [Int] = NodeDiscovery.defaultLocalNodePorts, strings: NodeLoginStrings = NodeLoginStrings()
    ) {
        self.callback = callback
        self.method = method
        self.strings = strings
        _model = StateObject(wrappedValue: NodeLoginModel(ports: ports))
    }

    public var body: some View {
        VStack(spacing: 12) {
            if model.isDiscovering {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(strings.searching).font(.subheadline).foregroundColor(theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("nodeDiscovering")
            } else {
                ForEach(model.discovered, id: \.self) { url in
                    option(NodeLoginModel.display(url), meta: strings.discoveredTag, selected: model.selected == url) {
                        model.selected = url
                    }
                    .accessibilityIdentifier("nodeOption-\(NodeLoginModel.display(url))")
                }
                if !model.discovered.isEmpty {
                    option(strings.manualOption, meta: nil, selected: model.selected == nil) {
                        model.selected = nil
                    }
                    .accessibilityIdentifier("nodeOption-custom")
                }
                if model.selected == nil {
                    field(strings.urlLabel, text: $model.customURL, placeholder: strings.urlPlaceholder)
                        .nodeURLKeyboard()
                        .onSubmit { Task { await connect() } }
                        .accessibilityIdentifier("nodeUrlInput")
                }
                if method == .password {
                    field(strings.usernameLabel, text: $username, placeholder: strings.usernamePlaceholder)
                        .accessibilityIdentifier("nodeUserInput")
                    field(
                        strings.passwordLabel, text: $password, placeholder: strings.passwordPlaceholder, secure: true
                    )
                        .onSubmit { Task { await connect() } }
                        .accessibilityIdentifier("nodePasswordInput")
                }
                if let error = model.error {
                    Text(error).font(.footnote).foregroundColor(theme.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 10) {
                    if model.isChecking || client.isLoading {
                        ProgressView().tint(theme.primaryText)
                    } else {
                        Image(systemName: "server.rack").font(.callout)
                    }
                    Text(strings.connectButton).font(.body.weight(.semibold))
                }
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: theme.controlHeight)
                .background(RoundedRectangle(cornerRadius: theme.radius).fill(theme.primary))
                .opacity(canConnect ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!canConnect || client.isLoading)
            .accessibilityIdentifier("nodeConnectButton")

            if !model.isDiscovering {
                Button {
                    model.rescan()
                } label: {
                    Label(strings.rescanButton, systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rescanButton")
            }
        }
        .onAppear { model.rescan() }
        .onDisappear { model.stop() }
    }

    private var canConnect: Bool {
        model.canConnect && (method == .loginPage || (!username.isEmpty && !password.isEmpty))
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.medium)).foregroundColor(theme.text)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .disableAutocorrection(true)
            .nodeURLKeyboardless()
            .foregroundColor(theme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: theme.controlHeight - 4)
            .background(RoundedRectangle(cornerRadius: theme.radius).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.border))
        }
    }

    private func option(_ title: String, meta: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? theme.text : theme.textTertiary)
                Text(title).foregroundColor(theme.text)
                Spacer()
                if let meta { Text(meta).font(.caption).foregroundColor(theme.textTertiary) }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: theme.radius).fill(
                    selected ? theme.primary.opacity(0.15) : theme.surface)
            )
            .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.border))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func connect() async {
        guard canConnect, let target = await model.resolveTarget() else { return }
        switch method {
        case .loginPage: await client.connectToNode(target, callback: callback)
        case .password: await client.login(nodeURL: target, username: username, password: password)
        }
    }
}

extension View {
    /// A URL keyboard with no autocapitalisation on iOS; unchanged elsewhere.
    @ViewBuilder
    func nodeURLKeyboard() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).keyboardType(.URL)
        #else
        self
        #endif
    }

    /// No autocapitalisation on iOS; unchanged elsewhere.
    @ViewBuilder
    func nodeURLKeyboardless() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
#endif
