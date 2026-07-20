import MeroKit
import MeroKitUI
import SwiftUI

/// A tiny SwiftUI app that drives the MeroKit frontend (`MeroClient` + views).
///
/// Launch with `-uitest-mock` to route the SDK through an in-app mock backend so
/// the XCUITest suite runs deterministically without a live node — the same idea
/// as Playwright's request interception.
@main
struct MeroSampleApp: App {
    @StateObject private var client: MeroClient

    init() {
        if CommandLine.arguments.contains("-uitest-mock") {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [UITestMockURLProtocol.self]
            _client = StateObject(wrappedValue: MeroClient(session: URLSession(configuration: config)))
        } else {
            _client = StateObject(wrappedValue: MeroClient())
        }
    }

    var body: some Scene {
        WindowGroup {
            MeroRootView()
                .environmentObject(client)
        }
    }
}
