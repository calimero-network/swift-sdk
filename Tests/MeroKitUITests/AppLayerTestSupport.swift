import Foundation
import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

/// Poll `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func appLayerEventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// A fresh, empty `UserDefaults` suite.
func appLayerDefaults() -> UserDefaults {
    let name = "merokitui-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// A node's login page in-process: reads the callback (with its `auth_state`)
/// off the login URL and answers it with tokens for `nodeURL`.
final class AppLayerLoginSheet: WebAuthenticating, @unchecked Sendable {
    let nodeURL: String
    let accessToken: String
    private let lock = NSLock()
    private var shown: [URL] = []

    init(nodeURL: String, accessToken: String = "good") {
        self.nodeURL = nodeURL
        self.accessToken = accessToken
    }

    var pages: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return shown
    }

    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        lock.lock()
        shown.append(url)
        lock.unlock()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let back = items.first { $0.name == "callback-url" }?.value ?? callback.url
        let fragment =
            "access_token=\(accessToken)&refresh_token=r1&node_url=\(nodeURL)&application_id=app1"
            + "&context_id=ctx1&context_identity=me1"
        return URL(string: "\(back)#\(fragment)")!
    }
}

/// The mock node the provider tests talk to: `/auth/validate` accepts
/// `Bearer good`, `/sse` answers as `sse` says, a few admin reads.
final class AppLayerNode: @unchecked Sendable {
    enum SseMode {
        case connect
        case permissionDenied
    }

    private let lock = NSLock()
    private var mode: SseMode = .connect
    private var contexts: [[String: Any]] = []
    private var migrationCalls = 0

    var sse: SseMode {
        get {
            lock.lock()
            defer { lock.unlock() }
            return mode
        }
        set {
            lock.lock()
            mode = newValue
            lock.unlock()
        }
    }

    var contextList: [[String: Any]] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return contexts
        }
        set {
            lock.lock()
            contexts = newValue
            lock.unlock()
        }
    }

    var migrationReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return migrationCalls
    }

    func install() {
        MockURLProtocol.setHandler { [self] req in handle(req) }
    }

    private func json(_ object: Any, status: Int = 200) -> MockURLProtocol.Stub {
        .init(
            status: status, headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func handle(_ req: URLRequest) -> MockURLProtocol.Stub {
        let path = req.url?.path ?? ""
        let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
        switch path {
        case "/auth/validate":
            return .init(status: bearer == "Bearer good" ? 200 : 401, headers: [:], body: Data())
        case "/auth/logout":
            return json(["data": ["success": true]])
        case "/sse":
            if sse == .permissionDenied {
                return .init(status: 403, headers: ["x-auth-error": "permission_denied"], body: Data())
            }
            let frame = "data: {\"type\":\"connect\",\"session_id\":\"s1\"}\n\n"
            return .init(status: 200, headers: [:], body: Data(frame.utf8), holdOpen: true)
        case "/sse/subscription":
            return json(["data": [:]])
        case "/admin-api/contexts":
            return json(["data": ["contexts": contextList]])
        case let other where other.hasSuffix("/migration-status"):
            lock.lock()
            migrationCalls += 1
            lock.unlock()
            return json([
                "targetVersion": 2, "expectedMembers": 1,
                "rollup": [
                    "migrated": 1, "inProgress": 0, "unknown": 0, "failed": 0, "total": 1, "allMigrated": true,
                    "membersPendingSignature": 0,
                ],
                "members": [],
            ])
        default:
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    static func context(_ id: String, app: String) -> [String: Any] {
        ["id": id, "applicationId": app, "contextStateHash": "h", "dagHeads": []]
    }
}

/// A test account session with real keys.
func appLayerSession(relay: String? = nil) throws -> DelegatedSession {
    let keys = try DeviceKeys(
        signSecret: Data(repeating: 0x21, count: 32), kemSecret: Data(repeating: 0x22, count: 32))
    return DelegatedSession(
        account: String(repeating: "ab", count: 32), credential: "cred", keys: keys, relayUrl: relay)
}
