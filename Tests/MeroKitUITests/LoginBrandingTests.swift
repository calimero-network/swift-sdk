#if canImport(SwiftUI)
import SwiftUI
import XCTest

@testable import MeroKitUI

/// `LoginBranding` carries every word `LoginView` shows, and the logo tile's
/// look, so an app built on the SDK can rebrand the whole sign-in surface.
/// The defaults are what the view always showed.
@MainActor
final class LoginBrandingTests: XCTestCase {
    func testDefaultsAreTheWordsLoginViewAlwaysShowed() {
        let branding = LoginBranding()
        XCTAssertEqual(branding.cloudButton, "Continue with Calimero Cloud")
        XCTAssertEqual(branding.cloudHint, "Opens the Calimero wallet to approve this device")
        XCTAssertEqual(branding.manualNodeLink, "Manually enter node URL")
        XCTAssertEqual(branding.useCloudLink, "Use Calimero Cloud instead")
        XCTAssertEqual(
            branding.customWalletNote(URL(string: "https://wallet.test")!),
            "Enrolling at https://wallet.test, not the hosted wallet.")
        XCTAssertEqual(branding.logoTileSize, 76)
        XCTAssertEqual(branding.logoTileCornerRadius, 22)
        XCTAssertNil(branding.logoTileBackground, "the theme's primary")
        XCTAssertTrue(branding.logoTileShadow)
    }

    func testNodeDefaultsAreTheWordsNodeLoginPanelAlwaysShowed() {
        let node = LoginBranding().node
        XCTAssertEqual(node.searching, "Searching for local nodes…")
        XCTAssertEqual(node.manualOption, "Enter node URL manually")
        XCTAssertEqual(node.discoveredTag, "local")
        XCTAssertEqual(node.urlLabel, "Node URL")
        XCTAssertEqual(node.urlPlaceholder, "http://localhost:4001")
        XCTAssertEqual(node.usernameLabel, "Username")
        XCTAssertEqual(node.usernamePlaceholder, "dev")
        XCTAssertEqual(node.passwordLabel, "Password")
        XCTAssertEqual(node.passwordPlaceholder, "Admin password")
        XCTAssertEqual(node.connectButton, "Connect to node")
        XCTAssertEqual(node.rescanButton, "Rescan local nodes")
    }

    func testEveryStringAndTheTileCanBeOverridden() {
        let branding = LoginBranding(
            cloudTitle: "Welcome", cloudSubtitle: "Sign in.", nodeTitle: "Your server", nodeSubtitle: "Self-hosted.",
            cloudButton: "Continue", cloudHint: nil, manualNodeLink: "Use my own server",
            useCloudLink: "Back to sign-in", customWalletNote: { "Custom wallet: \($0.host ?? "")" },
            node: NodeLoginStrings(searching: "Looking…", connectButton: "Connect"),
            logoTileSize: 64, logoTileCornerRadius: 32, logoTileBackground: .white, logoTileShadow: false)
        XCTAssertNil(branding.cloudHint, "nil hides the hint")
        XCTAssertEqual(branding.manualNodeLink, "Use my own server")
        XCTAssertEqual(branding.useCloudLink, "Back to sign-in")
        XCTAssertEqual(branding.customWalletNote(URL(string: "https://w.test")!), "Custom wallet: w.test")
        XCTAssertEqual(branding.node.searching, "Looking…")
        XCTAssertEqual(branding.node.connectButton, "Connect")
        XCTAssertEqual(branding.node.rescanButton, "Rescan local nodes", "unset node strings keep their default")
        XCTAssertEqual(branding.logoTileSize, 64)
        XCTAssertEqual(branding.logoTileCornerRadius, 32)
        XCTAssertEqual(branding.logoTileBackground, .white)
        XCTAssertFalse(branding.logoTileShadow)
    }

    /// The panels' public initialisers still compile as they did, and take
    /// the branding's words when given them.
    func testPanelsTakeTheBrandingsWords() {
        let panel = AccountSignInPanel(onEnrol: {})
        XCTAssertEqual(panel.hint, "Opens the Calimero wallet to approve this device")
        let quiet = AccountSignInPanel(hint: nil, onEnrol: {})
        XCTAssertNil(quiet.hint)
        _ = NodeLoginPanel(callback: .scheme("app", path: "auth"))
        _ = NodeLoginPanel(callback: .scheme("app", path: "auth"), strings: NodeLoginStrings(connectButton: "Go"))
        _ = LoginView(callbackScheme: "app", branding: LoginBranding(manualNodeLink: "Own server"))
    }
}
#endif
