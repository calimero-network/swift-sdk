#if canImport(SwiftUI)
import SwiftUI

/// The signed-in screen: who is signed in and through which relay, a demo
/// read, and sign out. Technical ids sit behind a disclosure.
public struct HomeView: View {
    @EnvironmentObject private var client: MeroClient

    /// Context id used by the demo "Run sample read" button.
    public var demoContextId: String
    public var demoMethod: String

    public init(demoContextId: String = "demo-context", demoMethod: String = "get") {
        self.demoContextId = demoContextId
        self.demoMethod = demoMethod
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Signed in")
                .font(.title2.weight(.bold))
                .accessibilityIdentifier("homeTitle")

            VStack(alignment: .leading, spacing: 6) {
                // A `Label` is an icon + a text: without `.combine` the identifier
                // lands on both, and a UI-test lookup by id finds two elements.
                Label(client.username, systemImage: "person.crop.circle")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("homeUser")
                Label(
                    client.nodeURL.isEmpty ? "No relay yet" : client.nodeURL,
                    systemImage: client.nodeURL.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "network"
                )
                .foregroundColor(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("homeNodeURL")
            }
            .font(.callout)

            if let note = client.cloudNote {
                Label(note, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("homeNote")
            }

            if let account = client.account {
                DisclosureGroup("Show technical details") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account").font(.caption).foregroundColor(.secondary)
                        Text(account).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.footnote)
            }

            Button("Run sample read") {
                Task { await client.runSampleRpc(contextId: demoContextId, method: demoMethod) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("runRpcButton")

            if let result = client.lastRpcResult {
                Text("Result: \(result)")
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

            Button(role: .destructive) {
                Task { await client.logout() }
            } label: {
                Text("Sign out").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("logoutButton")
        }
        .padding()
    }
}
#endif
