import Foundation
import MeroKit

// A runnable tour of MeroKit.
//
//   swift run MeroExample
//
// With no environment configured it runs the OFFLINE demo (SSO URL building,
// capability math, JWT/token parsing) — everything that needs no node.
//
// Point it at a live node to run the FULL online flow:
//
//   MERO_NODE_URL=http://localhost:4001 \
//   MERO_USERNAME=dev MERO_PASSWORD=dev-password \
//   MERO_BOOTSTRAP_SECRET=some-secret \
//   swift run MeroExample

func env(_ key: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
    return value
}

func section(_ title: String) {
    print("\n== \(title) ==")
}

@main
struct MeroExample {
    static func main() async {
        print("MeroKit example")

        offlineDemo()

        guard let nodeURLString = env("MERO_NODE_URL"), let nodeURL = URL(string: nodeURLString) else {
            print("\nNo MERO_NODE_URL set — skipping the online flow.")
            print("Set MERO_NODE_URL / MERO_USERNAME / MERO_PASSWORD to run the full tour.")
            return
        }

        do {
            try await onlineFlow(nodeURL: nodeURL)
        } catch {
            print("\nOnline flow failed: \(error)")
            exit(1)
        }
    }

    // MARK: - Offline (no node needed)

    static func offlineDemo() {
        section("SSO login URL")
        let loginURL = Mero.buildAuthLoginUrl(
            nodeUrl: "https://node.example",
            options: AuthLoginOptions(
                callbackUrl: "myapp://auth-callback",
                mode: "login",
                permissions: ["admin"]
            )
        )
        print("Open this in ASWebAuthenticationSession:\n  \(loginURL)")

        section("Parse an SSO callback")
        let callbackURL =
            "myapp://auth-callback#access_token=AAA&refresh_token=RRR&context_id=ctx1&node_url=https%3A%2F%2Fnode.example"
        if let parsed = Mero.parseAuthCallback(callbackURL) {
            print("accessToken=\(parsed.accessToken) contextId=\(parsed.contextId) nodeUrl=\(parsed.nodeUrl)")
        }

        section("Capability bitmask")
        var mask: UInt32 = 0
        mask = Capabilities.withCap(mask, Capabilities.canInviteMembers)
        mask = Capabilities.withCap(mask, Capabilities.manageMembers)
        print(
            "mask=\(mask) canInvite=\(Capabilities.hasCap(mask, Capabilities.canInviteMembers)) "
                + "canCreateContext=\(Capabilities.hasCap(mask, Capabilities.canCreateContext))")

        section("Dynamic JSON value")
        let args: [String: JSONValue] = ["id": "42", "limit": 10, "verbose": true]
        print("rpc argsJson would be: \(args)")
    }

    // MARK: - Online (needs a live node)

    static func onlineFlow(nodeURL: URL) async throws {
        let mero = Mero(config: MeroConfig(baseURL: nodeURL, tokenStore: MemoryTokenStore()))

        section("Node health / providers")
        let health = try await mero.auth.getHealth()
        print("auth health: \(health.status)")
        let providers = try await mero.auth.getProviders()
        print("providers: \(providers.providers.map(\.name)) (count \(providers.count))")

        section("Authenticate")
        let creds = Credentials(
            username: env("MERO_USERNAME") ?? "dev",
            password: env("MERO_PASSWORD") ?? "dev-password",
            bootstrapSecret: env("MERO_BOOTSTRAP_SECRET")
        )
        let tokens = try await mero.authenticate(creds)
        print("authenticated — access token …\(tokens.accessToken.suffix(8)), expires \(tokens.expiresAt)")
        let authed = await mero.isAuthenticated
        print("isAuthenticated: \(authed)")

        section("Identity")
        let identity = try await mero.auth.getIdentity()
        print("service=\(identity.service) version=\(identity.version) mode=\(identity.authenticationMode)")

        section("List contexts")
        do {
            let result = try await mero.admin.getContexts()
            print("contexts: \(result.contexts.count)")
        } catch {
            print("getContexts not available on this node: \(error)")
        }

        section("Logout")
        await mero.logout()
        let stillAuthed = await mero.isAuthenticated
        print("isAuthenticated after logout: \(stillAuthed)")

        print("\nOnline flow complete ✅")
    }
}
