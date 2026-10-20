#if canImport(SwiftUI)
import SwiftUI

/// Which ways to sign in ``LoginView`` offers.
public enum LoginMode: String, Sendable, CaseIterable {
    /// Calimero Cloud, with a "Manually enter node URL" link under it.
    case cloudAndNode
    /// Calimero Cloud alone.
    case cloudOnly
    /// A node URL alone (a node the user runs).
    case nodeOnly

    /// The ``LoginModalTab``s this mode offers, first shown first.
    public var tabs: [LoginModalTab] {
        switch self {
        case .cloudAndNode: return [.cloud, .node]
        case .cloudOnly: return [.cloud]
        case .nodeOnly: return [.node]
        }
    }

    /// The mode that offers `tabs` (the older `tabs:` initialisers).
    public init(tabs: [LoginModalTab]) {
        let hasCloud = tabs.contains(.cloud) || tabs.isEmpty
        let hasNode = tabs.contains(.node)
        self = hasCloud && hasNode ? .cloudAndNode : (hasNode ? .nodeOnly : .cloudOnly)
    }
}

/// How a node sign-in authenticates once its URL is chosen.
public enum NodeSignInMethod: String, Sendable {
    /// Open the node's own login page in the system sheet; the app never sees
    /// a password. The default.
    case loginPage
    /// Admin username and password typed into the app — for development nodes
    /// (a local `merod`).
    case password
}

/// The words, mark and logo tile ``LoginView`` shows. Every field has a
/// default, and the defaults are what ``LoginView`` has always shown, so an
/// app sets only what it rebrands.
///
/// Colours, radii, type and the glow behind the hero come from the
/// environment's ``MeroTheme`` (``MeroTheme/showsGlow`` turns the glow off).
public struct LoginBranding {
    /// Over the Cloud sign-in. Default "Welcome to Calimero".
    public var cloudTitle: String
    public var cloudSubtitle: String
    /// Over the node sign-in. Default "Connect to a node".
    public var nodeTitle: String
    public var nodeSubtitle: String
    /// The Cloud button's label. Default "Continue with Calimero Cloud".
    public var cloudButton: String
    /// The line under the Cloud button; `nil` hides it. Default "Opens the
    /// Calimero wallet to approve this device".
    public var cloudHint: String?
    /// The link from the Cloud side to the node side
    /// (``LoginMode/cloudAndNode``). Default "Manually enter node URL".
    public var manualNodeLink: String
    /// The link from the node side back to Cloud. Default "Use Calimero Cloud instead".
    public var useCloudLink: String
    /// The note shown when enrolment goes to a wallet other than the hosted
    /// one, given its URL. Default "Enrolling at <url>, not the hosted wallet."
    public var customWalletNote: @Sendable (URL) -> String
    /// The words of the node side.
    public var node: NodeLoginStrings
    /// The mark in the tile at the top; the Calimero logo when nil.
    public var logo: Image?
    /// The logo tile's side, in points. Default 76.
    public var logoTileSize: CGFloat
    /// The logo tile's corner radius. Default 22.
    public var logoTileCornerRadius: CGFloat
    /// The tile's fill; the theme's `primary` when nil.
    public var logoTileBackground: Color?
    /// Whether the tile casts its coloured shadow. Default `true`.
    public var logoTileShadow: Bool

    public init(
        cloudTitle: String = "Welcome to Calimero",
        cloudSubtitle: String =
            "Private, peer-to-peer apps. Sign in with your passkey; your account key never leaves the wallet.",
        nodeTitle: String = "Connect to a node",
        nodeSubtitle: String = "Sign in to a Calimero node you run.",
        cloudButton: String = "Continue with Calimero Cloud",
        logo: Image? = nil,
        cloudHint: String? = "Opens the Calimero wallet to approve this device",
        manualNodeLink: String = "Manually enter node URL",
        useCloudLink: String = "Use Calimero Cloud instead",
        customWalletNote: @escaping @Sendable (URL) -> String = LoginBranding.defaultCustomWalletNote,
        node: NodeLoginStrings = NodeLoginStrings(),
        logoTileSize: CGFloat = 76,
        logoTileCornerRadius: CGFloat = 22,
        logoTileBackground: Color? = nil,
        logoTileShadow: Bool = true
    ) {
        self.cloudTitle = cloudTitle
        self.cloudSubtitle = cloudSubtitle
        self.nodeTitle = nodeTitle
        self.nodeSubtitle = nodeSubtitle
        self.cloudButton = cloudButton
        self.logo = logo
        self.cloudHint = cloudHint
        self.manualNodeLink = manualNodeLink
        self.useCloudLink = useCloudLink
        self.customWalletNote = customWalletNote
        self.node = node
        self.logoTileSize = logoTileSize
        self.logoTileCornerRadius = logoTileCornerRadius
        self.logoTileBackground = logoTileBackground
        self.logoTileShadow = logoTileShadow
    }

    /// "Enrolling at <url>, not the hosted wallet."
    public static let defaultCustomWalletNote: @Sendable (URL) -> String = {
        "Enrolling at \($0.absoluteString), not the hosted wallet."
    }
}

/// The words ``NodeLoginPanel`` shows. Every field has a default.
public struct NodeLoginStrings: Sendable, Equatable {
    /// While discovery runs. Default "Searching for local nodes…".
    public var searching: String
    /// The option for a URL not found by discovery. Default "Enter node URL manually".
    public var manualOption: String
    /// The tag beside a discovered node. Default "local".
    public var discoveredTag: String
    /// Default "Node URL".
    public var urlLabel: String
    /// Default "http://localhost:4001".
    public var urlPlaceholder: String
    /// Default "Username".
    public var usernameLabel: String
    /// Default "dev".
    public var usernamePlaceholder: String
    /// Default "Password".
    public var passwordLabel: String
    /// Default "Admin password".
    public var passwordPlaceholder: String
    /// Default "Connect to node".
    public var connectButton: String
    /// Default "Rescan local nodes".
    public var rescanButton: String

    public init(
        searching: String = "Searching for local nodes…",
        manualOption: String = "Enter node URL manually",
        discoveredTag: String = "local",
        urlLabel: String = "Node URL",
        urlPlaceholder: String = "http://localhost:4001",
        usernameLabel: String = "Username",
        usernamePlaceholder: String = "dev",
        passwordLabel: String = "Password",
        passwordPlaceholder: String = "Admin password",
        connectButton: String = "Connect to node",
        rescanButton: String = "Rescan local nodes"
    ) {
        self.searching = searching
        self.manualOption = manualOption
        self.discoveredTag = discoveredTag
        self.urlLabel = urlLabel
        self.urlPlaceholder = urlPlaceholder
        self.usernameLabel = usernameLabel
        self.usernamePlaceholder = usernamePlaceholder
        self.passwordLabel = passwordLabel
        self.passwordPlaceholder = passwordPlaceholder
        self.connectButton = connectButton
        self.rescanButton = rescanButton
    }
}
#endif
