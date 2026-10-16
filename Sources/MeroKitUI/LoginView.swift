#if canImport(SwiftUI)
import SwiftUI

/// Sign-in, bound to ``MeroClient``: a **Cloud** tab — one "Continue with
/// Calimero" button that opens the Calimero wallet in the system auth sheet,
/// the same shape as "Sign in with Google" — and a **Node** tab with the local
/// nodes discovery found and a URL field, which opens the node's own login
/// page. (== mero-react `LoginModal` with its `node` and `cloud` tabs.)
///
/// It opens on the Cloud tab unless told otherwise; pass `tabs: [.cloud]` for
/// the Cloud sign-in alone. Colours come from the environment's ``MeroTheme``.
///
/// Accessibility identifiers for UI tests: `loginTitle`, `loginError`,
/// `cloudSignInButton` (the button), `loginButton` (the Cloud panel),
/// `loginTabs`, and on the Node tab `nodeDiscovering`, `nodeOption-<host:port>`,
/// `nodeOption-custom`, `nodeUrlInput`, `rescanButton` and `nodeConnectButton`.
@MainActor
public struct LoginView: View {
    @EnvironmentObject private var client: MeroClient
    @Environment(\.meroTheme) private var theme

    private let callback: CloudCallback
    private let nodeCallback: CloudCallback
    private let tabs: [LoginModalTab]
    @State private var tab: LoginModalTab

    /// - Parameters:
    ///   - callbackScheme: the app's URL scheme the wallet (`<scheme>://enrol`)
    ///     and a node's login page (`<scheme>://auth`) return to.
    ///   - tabs: which tabs to offer, in order.
    ///   - initialTab: the tab it opens on.
    public init(callbackScheme: String, tabs: [LoginModalTab] = [.cloud, .node], initialTab: LoginModalTab = .cloud) {
        self.init(
            callback: .scheme(callbackScheme), nodeCallback: .scheme(callbackScheme, path: "auth"), tabs: tabs,
            initialTab: initialTab)
    }

    /// Return through `callback` (an https Universal Link, say), and from a
    /// node's login page through `nodeCallback` (the same host's `/auth` by default).
    public init(
        callback: CloudCallback, nodeCallback: CloudCallback? = nil, tabs: [LoginModalTab] = [.cloud, .node],
        initialTab: LoginModalTab = .cloud
    ) {
        self.callback = callback
        self.nodeCallback = nodeCallback ?? Self.authCallback(for: callback)
        let offered = tabs.isEmpty ? [.cloud] : tabs
        self.tabs = offered
        _tab = State(initialValue: offered.contains(initialTab) ? initialTab : offered[0])
    }

    static func authCallback(for callback: CloudCallback) -> CloudCallback {
        switch callback {
        case .scheme(let scheme, _): return .scheme(scheme, path: "auth")
        case .https(let host, _): return .https(host: host, path: "/auth")
        }
    }

    public var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            CalimeroLogo(size: 28, color: theme.primaryText)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: theme.radius + 2).fill(theme.primary))

            VStack(spacing: 8) {
                Text(tab == .node ? "Connect to a node" : "Sign in to Calimero")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("loginTitle")
            }

            if tabs.count > 1 {
                Picker("How to connect", selection: $tab) {
                    ForEach(tabs) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("loginTabs")
            }

            if let error = client.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundColor(theme.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: theme.radius + 2).fill(theme.error.opacity(0.1)))
                    .accessibilityIdentifier("loginError")
            }

            switch tab {
            case .cloud:
                AccountSignInPanel(note: client.cloudNote, isWorking: client.isLoading) {
                    Task { await client.signInWithCloud(callback: callback) }
                }
            case .node:
                NodeLoginPanel(callback: nodeCallback)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 480)
    }
}

/// The Cloud tab: one button to the wallet, and what the last enrolment had
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
    public var onEnrol: () -> Void

    public init(
        note: String? = nil, isWorking: Bool = false, customWalletURL: URL? = nil, onEnrol: @escaping () -> Void
    ) {
        self.note = note
        self.isWorking = isWorking
        self.customWalletURL = customWalletURL
        self.onEnrol = onEnrol
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text(
                "You'll approve this device with your passkey on the Calimero wallet, then come straight back. "
                    + "Your account key never leaves the wallet; this app only receives a certificate for its own "
                    + "device key."
            )
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("accountNote")
            }

            Button(action: onEnrol) {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView().tint(theme.primaryText)
                    } else {
                        Image(systemName: "key.fill").font(.system(size: 14, weight: .semibold))
                    }
                    Text("Continue with Calimero").font(.body.weight(.semibold))
                }
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: theme.radius + 2).fill(theme.primary))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius + 2).stroke(Color.black.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityIdentifier("cloudSignInButton")

            Text("Uses the system sign-in sheet. Nothing to paste in.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let customWalletURL {
                Text("Enrolling at \(customWalletURL.absoluteString), not the hosted wallet.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loginButton")
    }
}

/// The Node tab: discovered local nodes and a URL field; Connect opens the
/// chosen node's login page. (== mero-react `LoginModal`'s node section.)
@MainActor
public struct NodeLoginPanel: View {
    @EnvironmentObject private var client: MeroClient
    @Environment(\.meroTheme) private var theme
    @StateObject private var model: NodeLoginModel
    private let callback: CloudCallback

    public init(callback: CloudCallback, ports: [Int] = NodeDiscovery.defaultLocalNodePorts) {
        self.callback = callback
        _model = StateObject(wrappedValue: NodeLoginModel(ports: ports))
    }

    public var body: some View {
        VStack(spacing: 12) {
            if model.isDiscovering {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching for local nodes…").font(.subheadline).foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("nodeDiscovering")
            } else {
                Text(
                    model.discovered.isEmpty
                        ? "No local node found. Enter a node URL to continue."
                        : "Select your Calimero node to continue."
                )
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

                ForEach(model.discovered, id: \.self) { url in
                    option(NodeLoginModel.display(url), meta: "local", selected: model.selected == url) {
                        model.selected = url
                    }
                    .accessibilityIdentifier("nodeOption-\(NodeLoginModel.display(url))")
                }
                if !model.discovered.isEmpty {
                    option("Enter node URL manually", meta: nil, selected: model.selected == nil) {
                        model.selected = nil
                    }
                    .accessibilityIdentifier("nodeOption-custom")
                }
                if model.selected == nil {
                    urlField
                }
                if let error = model.error {
                    Text(error).font(.footnote).foregroundColor(theme.error)
                }
                Button("↻ Rescan local nodes") { model.rescan() }
                    .font(.footnote)
                    .accessibilityIdentifier("rescanButton")
            }

            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 8) {
                    if model.isChecking || client.isLoading { ProgressView().tint(theme.primaryText) }
                    Text("Connect").font(.body.weight(.semibold))
                }
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: theme.radius + 2).fill(theme.primary))
                .opacity(model.canConnect ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!model.canConnect || client.isLoading)
            .accessibilityIdentifier("nodeConnectButton")
        }
        .onAppear { model.rescan() }
        .onDisappear { model.stop() }
    }

    private var urlField: some View {
        TextField("https://your-node-url.calimero.network", text: $model.customURL)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .onSubmit { Task { await connect() } }
            .accessibilityIdentifier("nodeUrlInput")
    }

    private func option(_ title: String, meta: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? theme.primary : .secondary)
                Text(title)
                Spacer()
                if let meta { Text(meta).font(.caption).foregroundColor(.secondary) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: theme.radius).stroke(Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func connect() async {
        guard model.canConnect, let target = await model.resolveTarget() else { return }
        await client.connectToNode(target, callback: callback)
    }
}
#endif
