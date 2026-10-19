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

/// The words and mark ``LoginView`` shows. Every field has a default.
public struct LoginBranding {
    /// Over the Cloud sign-in. Default "Welcome to Calimero".
    public var cloudTitle: String
    public var cloudSubtitle: String
    /// Over the node sign-in. Default "Connect to a node".
    public var nodeTitle: String
    public var nodeSubtitle: String
    /// The Cloud button's label. Default "Continue with Calimero Cloud".
    public var cloudButton: String
    /// The mark in the tile at the top; the Calimero logo when nil.
    public var logo: Image?

    public init(
        cloudTitle: String = "Welcome to Calimero",
        cloudSubtitle: String =
            "Private, peer-to-peer apps. Sign in with your passkey; your account key never leaves the wallet.",
        nodeTitle: String = "Connect to a node",
        nodeSubtitle: String = "Sign in to a Calimero node you run.",
        cloudButton: String = "Continue with Calimero Cloud",
        logo: Image? = nil
    ) {
        self.cloudTitle = cloudTitle
        self.cloudSubtitle = cloudSubtitle
        self.nodeTitle = nodeTitle
        self.nodeSubtitle = nodeSubtitle
        self.cloudButton = cloudButton
        self.logo = logo
    }
}
#endif
