#if canImport(SwiftUI)
import SwiftUI

/// Routes between login and home based on ``MeroClient`` auth state. Drop this in
/// as your root view and inject a `MeroClient` via `.environmentObject`.
public struct MeroRootView: View {
    @EnvironmentObject private var client: MeroClient

    private let defaultNodeURL: String

    public init(defaultNodeURL: String = "http://localhost:4001") {
        self.defaultNodeURL = defaultNodeURL
    }

    public var body: some View {
        Group {
            if client.isAuthenticated {
                HomeView()
            } else {
                LoginView(defaultNodeURL: defaultNodeURL)
            }
        }
    }
}
#endif
