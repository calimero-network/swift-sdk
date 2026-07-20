#if canImport(SwiftUI)
import SwiftUI

/// The signed-in screen: shows session info, a demo RPC button, and logout.
public struct HomeView: View {
    @EnvironmentObject private var client: MeroClient

    /// Context id used by the demo "Run RPC" button.
    public var demoContextId: String
    public var demoMethod: String

    public init(demoContextId: String = "demo-context", demoMethod: String = "get") {
        self.demoContextId = demoContextId
        self.demoMethod = demoMethod
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Signed in")
                .font(.title2).bold()
                .accessibilityIdentifier("homeTitle")

            VStack(alignment: .leading, spacing: 4) {
                Text("Node: \(client.nodeURL)").accessibilityIdentifier("homeNodeURL")
                Text("User: \(client.username)").accessibilityIdentifier("homeUser")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Run sample RPC") {
                Task { await client.runSampleRpc(contextId: demoContextId, method: demoMethod) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("runRpcButton")

            if let result = client.lastRpcResult {
                Text("RPC result: \(result)")
                    .font(.footnote)
                    .accessibilityIdentifier("rpcResult")
            }

            if let error = client.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.footnote)
                    .accessibilityIdentifier("homeError")
            }

            Spacer()

            Button("Log Out") {
                Task { await client.logout() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier("logoutButton")
        }
        .padding()
    }
}
#endif
