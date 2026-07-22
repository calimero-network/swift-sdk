import MeroKit
import MeroKitUI
import SwiftUI

/// The MeroKit sample iOS app.
///
/// Two modes:
/// - Normal launch → the **SDK Explorer** (`ExplorerRootView`): a Calimero-branded
///   app that signs in to a real node and exercises every MeroKit method.
/// - `-uitest-mock` launch arg → a tiny, deterministic login→home→rpc→logout flow
///   routed through an in-app mock backend. This is what the XCUITest suite drives,
///   so it needs no node and stays stable in CI.
@main
struct MeroSampleApp: App {
    private let uitestMock = CommandLine.arguments.contains("-uitest-mock")
    @StateObject private var mockClient: MeroClient
    @StateObject private var session = MeroSession()

    init() {
        if CommandLine.arguments.contains("-uitest-mock") {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [UITestMockURLProtocol.self]
            _mockClient = StateObject(wrappedValue: MeroClient(session: URLSession(configuration: config)))
        } else {
            _mockClient = StateObject(wrappedValue: MeroClient())
        }
    }

    var body: some Scene {
        WindowGroup {
            if uitestMock {
                MeroRootView().environmentObject(mockClient)
            } else {
                ExplorerRootView().environmentObject(session)
            }
        }
    }
}
