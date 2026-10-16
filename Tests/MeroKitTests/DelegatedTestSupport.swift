import Foundation
import MeroKitTestSupport

@testable import MeroKit

/// Shared inputs for the delegated-account and transport tests: one device,
/// one wallet-certified account, and the relay routes those tests serve.
enum DelegatedFixture {
    static let relay = "https://relay.test"
    static let cloud = URL(string: "https://cloud.test")!
    static let keys = try! DeviceKeys(
        signSecret: Data(repeating: 0x07, count: 32), kemSecret: Data(repeating: 0x08, count: 32))
    static let nodeSeed = Data(repeating: 0x42, count: 32)
    static let wallet = TestWallet()

    /// The relay's node key, as its mock attestation binds it.
    static var nodeKey: String { Hex.encode(try! Ed25519.publicKey(seed: nodeSeed)) }

    static func rep(_ byte: String, _ count: Int = 32) -> String { String(repeating: byte, count: count) }

    /// The wallet's certificate for ``keys``, signed once: CryptoKit's Ed25519
    /// is randomized, so re-signing on every read would give each session a
    /// different credential and break byte comparisons of ops that embed it.
    static let enrolled: EnrolmentCallback = wallet.approve(keys, state: nil)

    static func session(relayUrl: String? = relay, executorAccount: String? = nil) -> DelegatedSession {
        let cb = enrolled
        return DelegatedSession(
            account: cb.account, credential: cb.credential, keys: keys, relayUrl: relayUrl,
            executorAccount: executorAccount)
    }

    static func relayClient(_ url: String = relay) -> RelayClient {
        let cb = enrolled
        return RelayClient(
            relayURL: url, authorAccount: cb.account, authorProof: cb.credential, keys: keys,
            nonces: MemoryWarrantNonceStore(), session: MockURLProtocol.makeSession())
    }

    /// A delegated environment over ``MockURLProtocol``, with a fresh store.
    static func environment(store: DelegatedAccountStore = .memory()) -> DelegatedEnvironment {
        DelegatedEnvironment(
            store: store, nonces: MemoryWarrantNonceStore(), urlSession: MockURLProtocol.makeSession(),
            relayKeyVerifier: TLSRelayKeyVerifier(allowMock: true), cloudBaseURL: cloud,
            audience: .codeSigningId("network.calimero.test"), sleep: { _ in })
    }

    /// `GET /admin-api/contexts/{ctx}/intents`: what a warrant must name.
    static func serveDescribe(_ rig: CloudRig, ctx: String) {
        rig.on(
            "GET", "/admin-api/contexts/\(ctx)/intents",
            json: """
                {"data":{"executorAccount":"\(rep("33"))","executorKey":"\(rep("77"))","canAuthorOnBehalf":true,
                 "groupId":"\(rep("99"))","releaseBytecodeId":"\(rep("44"))","releaseVersion":"1.0.0"}}
                """)
    }

    /// `POST /admin-api/tee/attest` answered with a mock quote bound to the
    /// request's nonce and ``nodeKey``.
    static func serveAttest(_ rig: CloudRig) {
        let key = try! Ed25519.publicKey(seed: nodeSeed)
        rig.on("POST", "/admin-api/tee/attest") { seen in
            let nonce = (try? Hex.decode(seen.json?["nonce"]?.stringValue ?? "", label: "n", bytes: 32)) ?? Data()
            let quote = Data("MOCK_TDX_QUOTE_V1".utf8) + nonce + RelayNodeKey.keyBinding(key)
            return CloudRig.stub(
                200,
                #"{"data":{"quoteB64":"\#(quote.base64EncodedString())","boundPublicKey":"\#(Hex.encode(key))"}}"#)
        }
    }

    /// `/auth/challenge` and `/auth/token`: an `account_proof` login.
    static func serveLogin(_ rig: CloudRig, accessToken: String = "relay-access") {
        rig.on("GET", "/auth/challenge", json: #"{"data":{"challenge":"\#(rep("c4"))"}}"#)
        rig.on(
            "POST", "/auth/token",
            json: #"{"data":{"access_token":"\#(accessToken)","refresh_token":"relay-refresh"}}"#)
    }

    /// An unsigned JWT whose `exp` is `exp` (Unix seconds).
    static func jwt(exp: TimeInterval) -> String {
        let payload = Data(#"{"exp":\#(Int(exp))}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJub25lIn0.\(payload).sig"
    }
}

/// Thread-safe list of strings a test records into.
final class DelegatedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
