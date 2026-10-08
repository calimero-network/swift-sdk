#if canImport(SwiftUI)
import SwiftUI

/// Routes between Cloud sign-in and home based on ``MeroClient`` auth state.
/// Drop this in as your root view and inject a `MeroClient` via
/// `.environmentObject`. A session from a previous launch is restored first.
public struct MeroRootView: View {
    @EnvironmentObject private var client: MeroClient

    private let callback: CloudCallback

    /// - Parameter callbackScheme: the app's URL scheme the wallet returns to.
    public init(callbackScheme: String) {
        self.callback = .scheme(callbackScheme)
    }

    public init(callback: CloudCallback) {
        self.callback = callback
    }

    public var body: some View {
        Group {
            if client.isAuthenticated {
                HomeView()
            } else {
                LoginView(callback: callback)
            }
        }
        .task { await client.restoreCloudSession() }
        .onOpenURL { url in
            Task { await client.handleEnrolmentCallback(url) }
        }
    }
}
#endif
