import MeroKit
import MeroKitUI
import SwiftUI

/// The MeroKit sample iOS app.
///
/// Two modes:
/// - Normal launch → the **SDK Explorer** (`ExplorerRootView`): Cloud sign-in
///   (wallet passkey → device certificate → hosted relay), the chat example on
///   the relay, and every MeroKit method.
/// - `-uitest-mock` → MeroKitUI's own `MeroRootView` (Cloud sign-in → home →
///   read → sign out) against an in-app mock Cloud + relay, with an in-app
///   wallet standing in for the web sheet. This is what the XCUITest suite
///   drives, so it needs no network and stays stable in CI.
///   `-uitest-enrol-callback <url>` makes the "wallet" answer with that exact
///   callback instead (e.g. `mero-sample://enrol#error=cancelled`).
@main
struct MeroSampleApp: App {
    private let uitestMock = CommandLine.arguments.contains("-uitest-mock")
    @StateObject private var mockClient: MeroClient
    @StateObject private var session: MeroSession

    init() {
        if CommandLine.arguments.contains("-uitest-mock") {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [UITestMockURLProtocol.self]
            let urlSession = URLSession(configuration: config)
            let cloud = CloudSignIn(
                config: CloudConfig(relayKeyVerifier: TLSRelayKeyVerifier(allowMock: true)),
                keyStore: .memory(), sessionStore: .memory(), nonces: MemoryWarrantNonceStore(),
                urlSession: urlSession)
            _mockClient = StateObject(
                wrappedValue: MeroClient(session: urlSession, cloud: cloud, webAuthenticator: UITestWallet()))
        } else {
            _mockClient = StateObject(wrappedValue: MeroClient())
        }
        _session = StateObject(
            wrappedValue: MeroSession(signIn: .keychain(), web: SystemWebAuthenticator()))
    }

    var body: some Scene {
        WindowGroup {
            if uitestMock {
                MeroRootView(callbackScheme: MeroSession.callbackScheme)
                    .environmentObject(mockClient)
            } else {
                ExplorerRootView().environmentObject(session)
            }
        }
    }
}
