import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The credential a routing read presents: the device certificate, and the
/// device key that signs the cloud's challenge. The secret never leaves the
/// process; only the signature travels.
public struct RoutingCredential: Sendable {
    /// The `AccountProof<DeviceCert>`, hex.
    public let credential: String
    /// The certified device's Ed25519 seed.
    public let deviceSecret: Data

    public init(credential: String, deviceSecret: Data) {
        self.credential = credential
        self.deviceSecret = deviceSecret
    }
}

/// A challenge the cloud minted. Opaque: the client signs it, never parses it.
public struct RoutingChallenge: Sendable, Equatable {
    /// The account or namespace it is bound to.
    public let boundTo: String
    public let nonce: String
    /// Epoch **milliseconds**.
    public let expiresAtMs: Int64
}

/// One relay that serves an account.
public struct CloudAccountRelay: Sendable, Equatable, Codable {
    public let peerId: String
    public let relayUrl: String?
    public let fresh: Bool
    /// The relay's own account (64 lowercase hex), the executor a delegated
    /// write through it names; `nil` when the cloud did not say.
    public let executorAccount: String?
    /// True when the cloud just assigned this relay to an account that had none.
    public let assigned: Bool

    public init(peerId: String, relayUrl: String?, fresh: Bool, executorAccount: String?, assigned: Bool) {
        self.peerId = peerId
        self.relayUrl = relayUrl
        self.fresh = fresh
        self.executorAccount = executorAccount
        self.assigned = assigned
    }
}

/// One node serving a namespace, as the routing read reports it.
public struct CloudNamespaceNode: Sendable, Equatable {
    public let peerId: String
    public let account: String?
    public let relayUrl: String?
    public let admitUrl: String?
    public let status: String
    public let fresh: Bool
    public let canAdmit: Bool
    public let authorshipReady: Bool
    public let teeRole: String?
    public let canExecute: Bool
}

/// What ``CloudClient/getNamespaceRouting(_:)`` reports.
public struct CloudNamespaceRouting: Sendable, Equatable {
    public let namespaceId: String
    public let nodes: [CloudNamespaceNode]
    public let servable: Bool
    public let writable: Bool
}

/// The relay ``CloudClient/chooseRelay(_:)`` picked, and why.
public struct RelayChoice: Sendable, Equatable {
    /// `nil` is still signed in: a new account earns a relay by redeeming an
    /// invitation.
    public let relayUrl: String?
    public let executorAccount: String?
    /// A note to show the person, or `nil` when a fresh relay was found.
    public let note: String?
}

/// The Calimero Cloud manager, for the reads a device-only mobile client needs:
/// which relays serve this account, and which nodes serve a namespace.
///
/// Port of the device-proven half of mero-js `CloudClient`. Both reads are
/// proven by the **device certificate** — a challenge from the cloud, signed by
/// the device key — not by a cloud login session.
public struct CloudClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://manager.cloud.calimero.network")!

    /// Flat prefix, NUL included — MDMA checks `DOMAIN ‖ nonce` against the raw
    /// message, not a `domainHash`.
    static let routingProofDomain = "calimero.mdma.routing-read.v1\u{0}"

    public let baseURL: URL
    public let routingCredential: RoutingCredential?
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: URL = CloudClient.defaultBaseURL, routingCredential: RoutingCredential? = nil,
        session: URLSession = .shared, timeout: TimeInterval = 10
    ) {
        self.baseURL = baseURL
        self.routingCredential = routingCredential
        self.session = session
        self.timeout = timeout
    }

    // MARK: - Routing proof

    /// Sign a cloud challenge: `base64(Ed25519(deviceSecret, DOMAIN ‖ utf8(nonce)))`.
    public static func signRoutingChallenge(nonce: String, deviceSecret: Data) throws -> String {
        var message = Data(routingProofDomain.utf8)
        message.append(Data(nonce.utf8))
        return try Ed25519.sign(seed: deviceSecret, message: message).base64EncodedString()
    }

    /// The `X-Calimero-Credential` / `-Nonce` / `-Signature` headers for one read.
    public static func routingProofHeaders(
        challenge: RoutingChallenge, credential: RoutingCredential
    ) throws -> [String: String] {
        [
            "X-Calimero-Credential": credential.credential,
            "X-Calimero-Nonce": challenge.nonce,
            "X-Calimero-Signature": try signRoutingChallenge(
                nonce: challenge.nonce, deviceSecret: credential.deviceSecret),
        ]
    }

    // MARK: - Account relays

    /// `GET /api/cloud/accounts/{account}/challenge` — public; the nonce is
    /// sealed to this account.
    public func getAccountRelaysChallenge(_ accountId: String) async throws -> RoutingChallenge {
        let body = try await getJSON("/api/cloud/accounts/\(escape(accountId))/challenge")
        return RoutingChallenge(
            boundTo: body["account_id"]?.stringValue ?? accountId,
            nonce: body["nonce"]?.stringValue ?? "",
            expiresAtMs: Int64(body["expires_at_ms"]?.doubleValue ?? 0))
    }

    /// Which relays serve this account. Proven with the device certificate, so
    /// it throws without a ``routingCredential`` rather than answering "none".
    public func getAccountRelays(_ accountId: String) async throws -> [CloudAccountRelay] {
        guard let routingCredential else {
            throw AccountError.notSignedIn(
                "getAccountRelays needs a routingCredential: this read is proven by the device certificate")
        }
        let challenge = try await getAccountRelaysChallenge(accountId)
        let headers = try Self.routingProofHeaders(challenge: challenge, credential: routingCredential)
        let body = try await getJSON("/api/cloud/accounts/\(escape(accountId))/relays", headers: headers)
        return (body["relays"]?.arrayValue ?? []).map { row in
            CloudAccountRelay(
                peerId: row["peer_id"]?.stringValue ?? "",
                relayUrl: row["relay_url"]?.stringValue,
                fresh: row["fresh"]?.boolValue == true,
                executorAccount: Self.accountHexOrNil(row["executor_account"]?.stringValue),
                assigned: row["assigned"]?.boolValue == true)
        }
    }

    /// Pick a relay as mero-react's `chooseRelay` does: a fresh one with an
    /// address, else any with an address (with a note), else none (still
    /// signed in, with a note on how to get one).
    public static func chooseRelay(_ relays: [CloudAccountRelay]) -> RelayChoice {
        let reachable = relays.filter { ($0.relayUrl ?? "").isEmpty == false }
        if let fresh = reachable.first(where: \.fresh) {
            return RelayChoice(relayUrl: fresh.relayUrl, executorAccount: fresh.executorAccount, note: nil)
        }
        if let first = reachable.first {
            return RelayChoice(
                relayUrl: first.relayUrl, executorAccount: first.executorAccount,
                note: "Connected through a relay whose last heartbeat has lapsed — it may not answer. "
                    + "It was the only one with an address.")
        }
        if !relays.isEmpty {
            let plural = relays.count == 1 ? "" : "s"
            return RelayChoice(
                relayUrl: nil, executorAccount: nil,
                note: "Signed in. Your account has \(relays.count) relay\(plural) assigned, but none has an "
                    + "address yet, so there is nowhere to write through for the moment.")
        }
        return RelayChoice(
            relayUrl: nil, executorAccount: nil,
            note: "Signed in, with nowhere to write yet: a new account is a member of nothing. Redeeming an "
                + "invitation admits this account to a namespace and gives it a relay.")
    }

    // MARK: - Namespace routing

    /// `GET /api/cloud/namespaces/{ns}/challenge` — public.
    public func getRoutingChallenge(_ namespaceId: String) async throws -> RoutingChallenge {
        let body = try await getJSON("/api/cloud/namespaces/\(escape(namespaceId))/challenge")
        return RoutingChallenge(
            boundTo: body["namespace_id"]?.stringValue ?? namespaceId,
            nonce: body["nonce"]?.stringValue ?? "",
            expiresAtMs: Int64(body["expires_at_ms"]?.doubleValue ?? 0))
    }

    /// Which nodes serve a namespace, and which can admit a join or relay a
    /// write. Proven with the device certificate when one is configured,
    /// anonymous otherwise.
    public func getNamespaceRouting(_ namespaceId: String) async throws -> CloudNamespaceRouting {
        var headers: [String: String] = [:]
        if let routingCredential {
            let challenge = try await getRoutingChallenge(namespaceId)
            headers = try Self.routingProofHeaders(challenge: challenge, credential: routingCredential)
        }
        let body = try await getJSON("/api/cloud/namespaces/\(escape(namespaceId))/admitters", headers: headers)
        let nodes = (body["admitters"]?.arrayValue ?? []).map { row -> CloudNamespaceNode in
            let account = row["account"]?.stringValue
            let relayUrl = row["relay_url"]?.stringValue
            let fresh = row["fresh"]?.boolValue == true
            let authorshipReady = row["authorship_ready"]?.boolValue == true
            let teeRole = row["tee_role"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let legacy = authorshipReady && relayUrl != nil && account != nil && fresh
            return CloudNamespaceNode(
                peerId: row["peer_id"]?.stringValue ?? "",
                account: account,
                relayUrl: relayUrl,
                admitUrl: row["admit_url"]?.stringValue,
                status: row["status"]?.stringValue ?? "",
                fresh: fresh,
                canAdmit: row["can_admit"]?.boolValue == true,
                authorshipReady: authorshipReady,
                teeRole: teeRole,
                canExecute: row["can_execute"]?.boolValue ?? legacy)
        }
        return CloudNamespaceRouting(
            namespaceId: body["namespace_id"]?.stringValue ?? namespaceId,
            nodes: nodes,
            servable: body["servable"]?.boolValue == true,
            writable: body["writable"]?.boolValue == true)
    }

    /// The node to send a signed join to, intersected with the invitation's
    /// signed `admitters` (a node assigned after the invitation answers 403).
    public func findAdmitter(_ namespaceId: String, admitters: [String] = []) async throws -> CloudNamespaceNode? {
        let routing = try await getNamespaceRouting(namespaceId)
        let allowed = Set(admitters.map { $0.lowercased() })
        return routing.nodes.first { node in
            node.canAdmit && (allowed.isEmpty || node.account.map { allowed.contains($0.lowercased()) } == true)
        }
    }

    // MARK: - HA for a founded namespace

    /// What to tell a person for each `enable-ha` refusal the cloud names. Every
    /// one leaves the namespace founded; only hosting was refused.
    public static let haRefusalMessages: [String: String] = [
        "account_not_linked":
            "Link this account to your cloud user in the wallet so invitees can find this namespace.",
        "account_linked_to_several_users":
            "This account is linked to more than one cloud user, so the cloud cannot tell whose plan hosts the "
            + "namespace: unlink it from all but one in the wallet.",
        "ha_request_pending":
            "Another namespace of this account is still waiting to be hosted; the cloud hosts one new namespace at "
            + "a time without a cloud sign-in.",
        "unknown_relay": "The cloud does not run the relay this namespace was founded on, so it cannot host it.",
        "relay_not_dialable":
            "The relay this namespace was founded on has not reported its address to the cloud yet; try again shortly.",
    ]

    /// Statuses whose `{"error": code}` names an ``AccountError/haRefused(code:status:body:)``.
    static let haRefusalCodes: [Int: Set<String>] = [
        409: ["account_not_linked", "account_linked_to_several_users", "ha_request_pending"],
        422: ["unknown_relay", "relay_not_dialable"],
    ]

    /// Enable HA for a namespace this account founded through a relay, with no
    /// cloud session: `POST /api/cloud/accounts/{account}/namespaces/{ns}/enable-ha`
    /// `{ownership_proof}` carrying the founder's claim (``AccountHaClaim``).
    ///
    /// The cloud bills the user the account is linked to through the wallet. A
    /// refusal it names is ``AccountError/haRefused(code:status:body:)``; any
    /// other failure is the plain HTTP error. Returns the cloud's body.
    @discardableResult
    public func enableHaAsAccount(
        namespaceId: String, salt: String, accountId: String, credential: String, keys: DeviceKeys,
        relayURL: String? = nil, ttlMs: Int64 = AccountHaClaim.defaultTTLMs
    ) async throws -> JSONValue {
        let proof = try AccountHaClaim.sign(
            namespaceId: namespaceId, accountId: accountId, salt: salt, credential: credential, keys: keys,
            relayURL: relayURL, ttlMs: ttlMs)
        let path =
            "/api/cloud/accounts/\(escape(accountId.lowercased()))/namespaces/\(escape(namespaceId.lowercased()))"
            + "/enable-ha"
        let request = AccountHTTP.jsonRequest(
            try AccountHTTP.url(baseURL.absoluteString, path), method: "POST",
            body: ["ownership_proof": proof.json], timeout: timeout)
        do {
            return try await AccountHTTP.send(request, session: session)
        } catch MeroError.http(let http) {
            if let code = Self.refusalCode(http.bodyText), Self.haRefusalCodes[http.status]?.contains(code) == true {
                throw AccountError.haRefused(code: code, status: http.status, body: http.bodyText)
            }
            throw MeroError.http(http)
        }
    }

    /// The `error` code of a refusal: `{"error": c}`, `{"detail": c}` or `{"detail": {"error": c}}`.
    static func refusalCode(_ body: String?) -> String? {
        guard let body, let json = try? MeroJSON.decode(JSONValue.self, from: Data(body.utf8)) else { return nil }
        return json["error"]?.stringValue ?? json["detail"]?.stringValue ?? json["detail"]?["error"]?.stringValue
    }

    // MARK: - Transport

    private func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? segment
    }

    private func getJSON(_ path: String, headers: [String: String] = [:]) async throws -> JSONValue {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw AccountError.invalidInput("bad cloud URL \(base + path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        // Set last so a caller header can never displace it.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await AccountHTTP.send(request, session: session)
    }

    static func accountHexOrNil(_ value: String?) -> String? {
        guard let value, value.count == 64, value == value.lowercased(), Hex.is32(value) else { return nil }
        return value
    }
}

/// The small JSON-over-URLSession transport the account layer uses for hosts
/// that are not a ``Mero`` node (the cloud manager, a relay's intents).
enum AccountHTTP {
    static func send(_ request: URLRequest, session: URLSession) async throws -> JSONValue {
        let (data, head) = try await sendRaw(request, session: session)
        if data.isEmpty || head.status == 204 { return .null }
        do {
            return try MeroJSON.decode(JSONValue.self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw MeroError.decoding("status \(head.status): \(snippet)")
        }
    }

    static func sendRaw(_ request: URLRequest, session: URLSession) async throws -> (Data, HeadResult) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw MeroError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MeroError.network("Non-HTTP response") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(65536), as: UTF8.self)
            throw MeroError.http(
                HTTPError(
                    status: http.statusCode,
                    statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized,
                    url: request.url?.absoluteString ?? "",
                    headers: headers,
                    bodyText: body.isEmpty ? nil : body))
        }
        return (data, HeadResult(status: http.statusCode, headers: headers))
    }

    /// A JSON request with a canonical (sorted-key) body — see ``CanonicalJSON``.
    static func jsonRequest(
        _ url: URL, method: String, body: JSONValue?, headers: [String: String] = [:], timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = CanonicalJSON.data(body)
        }
        return request
    }

    /// `base` with trailing slashes trimmed, plus `path`.
    static func url(_ base: String, _ path: String) throws -> URL {
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path) else {
            throw AccountError.invalidInput("bad URL \(trimmed + path)")
        }
        return url
    }
}
