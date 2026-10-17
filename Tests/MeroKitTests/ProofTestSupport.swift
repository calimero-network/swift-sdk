import Foundation
import MeroKitTestSupport

/// One request as the mock node saw it, headers included.
struct ProofTransportSeen: Sendable {
    let method: String
    let url: String
    let proof: String?
    let authorization: String?
    let body: Data
}

/// The requests a proof-transport test's mock node received.
final class ProofTransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ProofTransportSeen] = []

    var requests: [ProofTransportSeen] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func append(_ req: URLRequest) {
        let entry = ProofTransportSeen(
            method: req.httpMethod ?? "GET", url: req.url?.absoluteString ?? "",
            proof: req.value(forHTTPHeaderField: "X-Calimero-Proof"),
            authorization: req.value(forHTTPHeaderField: "Authorization"), body: FakeNode.body(req))
        lock.lock(); defer { lock.unlock() }
        seen.append(entry)
    }
}
