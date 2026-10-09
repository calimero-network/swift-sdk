import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a relay tells a member about a context before they sign
/// (`GET /admin-api/contexts/{ctx}/intents`).
public struct RelayDescription: Codable, Sendable, Equatable {
    public let executorAccount: String
    public let executorKey: String
    public let canAuthorOnBehalf: Bool
    public let groupId: String
    public let releaseBytecodeId: String
    public let releaseVersion: String

    public init(
        executorAccount: String, executorKey: String, canAuthorOnBehalf: Bool, groupId: String,
        releaseBytecodeId: String, releaseVersion: String
    ) {
        self.executorAccount = executorAccount; self.executorKey = executorKey
        self.canAuthorOnBehalf = canAuthorOnBehalf; self.groupId = groupId
        self.releaseBytecodeId = releaseBytecodeId; self.releaseVersion = releaseVersion
    }

    enum CodingKeys: String, CodingKey {
        case executorAccount, executorKey, canAuthorOnBehalf, groupId, releaseBytecodeId, releaseVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executorAccount = try c.decodeIfPresent(String.self, forKey: .executorAccount) ?? ""
        executorKey = try c.decodeIfPresent(String.self, forKey: .executorKey) ?? ""
        canAuthorOnBehalf = try c.decodeIfPresent(Bool.self, forKey: .canAuthorOnBehalf) ?? false
        groupId = try c.decodeIfPresent(String.self, forKey: .groupId) ?? ""
        releaseBytecodeId = try c.decodeIfPresent(String.self, forKey: .releaseBytecodeId) ?? ""
        releaseVersion = try c.decodeIfPresent(String.self, forKey: .releaseVersion) ?? ""
    }
}

/// `GET /admin-api/groups/{g}/context-intents[?author=]`.
public struct CreationDescription: Codable, Sendable, Equatable {
    public let executorAccount: String
    public let executorKey: String
    public let groupId: String
    public let canCreateOnBehalf: Bool
    /// Present only when `author` was asked about.
    public let authorMayCreate: Bool?
}

/// `GET /admin-api/groups/{g}/governance-intents`.
public struct GovernanceDescription: Codable, Sendable, Equatable {
    public let executorAccount: String
    public let executorKey: String
    public let groupId: String
    public let canActOnBehalf: Bool
}

/// A warranted write's outcome.
public struct IntentResult: Sendable, Equatable {
    /// The context root after the run.
    public let rootHash: String?
    public let returns: JSONValue?
}

/// The relay's account and node key, as a founding warrant names them.
///
/// For a namespace that does not exist yet the relay cannot be asked
/// (`describeGovernance` has nothing to answer about), so this comes from the
/// cloud (the account) and the relay's **attested** node key — never from an
/// unauthenticated discovery answer.
public struct RelayExecutor: Sendable, Equatable {
    public let executorAccount: String
    public let executorKey: String

    public init(executorAccount: String, executorKey: String) {
        self.executorAccount = executorAccount
        self.executorKey = executorKey
    }
}

/// The application a founded namespace runs: `TargetApplicationSet`'s inputs.
public struct FoundingApplication: Sendable, Equatable {
    public let applicationId: String
    public let package: String
    public let version: String

    public init(applicationId: String, package: String, version: String) {
        self.applicationId = applicationId
        self.package = package
        self.version = version
    }
}

/// A namespace founded through a relay (mero-js `FoundedNamespace`).
public struct FoundedNamespace: Sendable, Equatable {
    /// `foundedNamespaceId(author, salt)`.
    public let namespaceId: String
    /// Keep it to prove founding later (HA): `(founder, salt)` reproduces the id.
    public let salt: String
    /// Whether the relay admitted itself as the namespace's first TEE.
    public let teeEnabled: Bool
    public let teeError: String?
    /// `nil` unless an application was asked for.
    public var applicationSet: Bool?
    public var applicationError: String?
    /// `nil` unless a default capability mask was asked for.
    public var defaultCapabilitiesSet: Bool?
    public var defaultCapabilitiesError: String?
}

/// A context created through a creation warrant.
public struct CreatedRelayContext: Codable, Sendable, Equatable {
    public let contextId: String
    public let groupId: String
    public let memberPublicKey: String
}

/// Writes (and reads) through a hosted relay as an account.
///
/// Port of mero-js `RelayClient`. A write is a **warrant**: the device signs
/// "run `method(args)` in `context`, executed by this relay, at most once
/// (nonce), until `notAfter`", and the relay runs it. No token is involved, so
/// writes work even before a Bearer session exists.
///
/// Reads go through ``query(contextId:method:argsJson:)``, which needs the
/// relay session's Bearer token (`tokenProvider`).
public struct RelayClient: Sendable {
    public let relayURL: String
    public let authorAccount: String
    /// The device certificate (`AccountProof<DeviceCert>`), hex.
    public let authorProof: String
    public let executorAccount: String?
    public let ttlSeconds: UInt64
    private let keys: DeviceKeys
    private let nonces: any WarrantNonceStore
    private let tokenProvider: @Sendable () async -> String?
    private let session: URLSession
    private let timeout: TimeInterval
    private let rateLimitRetries: Int

    public init(
        relayURL: String, authorAccount: String, authorProof: String, keys: DeviceKeys,
        nonces: any WarrantNonceStore, executorAccount: String? = nil, ttlSeconds: UInt64 = 300,
        tokenProvider: @escaping @Sendable () async -> String? = { nil }, session: URLSession = .shared,
        timeout: TimeInterval = 15, rateLimitRetries: Int = 3
    ) {
        var trimmed = relayURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.relayURL = trimmed
        self.authorAccount = authorAccount.lowercased()
        self.authorProof = authorProof
        self.keys = keys
        self.nonces = nonces
        self.executorAccount = executorAccount?.lowercased()
        self.ttlSeconds = ttlSeconds
        self.tokenProvider = tokenProvider
        self.session = session
        self.timeout = timeout
        self.rateLimitRetries = rateLimitRetries
    }

    // MARK: - Data writes

    public func describe(_ contextId: String) async throws -> RelayDescription {
        try await data(RelayDescription.self, "GET", "/admin-api/contexts/\(escape(contextId))/intents")
    }

    /// Run `method(args)` in `contextId` through the relay, as the account.
    ///
    /// On a nonce refusal the sequence is recovered from the node's own record
    /// (`warrant-nonce`) and the write retried once.
    public func execute(
        contextId: String, method: String, argsJson: JSONValue = [:]
    ) async throws -> IntentResult {
        do {
            return try await executeOnce(contextId: contextId, method: method, argsJson: argsJson)
        } catch AccountError.intentRefused(_, let retryable, _) where retryable {
            try await recoverNonce(contextId: contextId)
            return try await executeOnce(contextId: contextId, method: method, argsJson: argsJson)
        }
    }

    private func executeOnce(contextId: String, method: String, argsJson: JSONValue) async throws -> IntentResult {
        let described = try await describe(contextId)
        let executor = try checkedExecutor(described.executorAccount, described.executorKey)
        let bytecodeId = Hex.encode(
            try Hex.decode(described.releaseBytecodeId, label: "the relay's releaseBytecodeId", bytes: 32))
        let warrant = try Warrants.signWarrant(
            Warrants.WarrantInput(
                context: contextId, authorAccount: authorAccount, executor: executor.account,
                executorKey: executor.key, releaseBytecodeId: bytecodeId,
                releaseVersion: described.releaseVersion, method: method, argsJson: argsJson,
                nonce: nonces.next(relay: relayURL), notAfter: notAfter()),
            keys: keys)
        let body = try await json(
            "POST", "/admin-api/contexts/\(escape(contextId))/intents",
            body: [
                "method": .string(method), "argsJson": argsJson, "warrant": .string(warrant),
                "authorProof": .string(authorProof),
            ])
        let data = body["data"] ?? .null
        let returns = data["returns"]
        return IntentResult(rootHash: data["rootHash"]?.stringValue, returns: returns == .null ? nil : returns)
    }

    /// Read `method(args)`: first as a session-authenticated query (for a
    /// method the app's ABI declares read-only), falling back to a warrant when
    /// the node says it is a write (409) or the query is unavailable.
    public func query(contextId: String, method: String, argsJson: JSONValue = [:]) async throws -> JSONValue? {
        let key = "\(relayURL)|\(contextId)|\(method)"
        if MethodKinds.shared.get(key) != .write, let token = await tokenProvider() {
            do {
                let body = try await json(
                    "POST", "/admin-api/contexts/\(escape(contextId))/query",
                    body: ["method": .string(method), "argsJson": argsJson], bearer: token, refuseAsIntent: false)
                MethodKinds.shared.set(key, .read)
                let returns = body["data"]?["returns"]
                return returns == .null ? nil : returns
            } catch MeroError.http(let http) where http.status == 409 {
                MethodKinds.shared.set(key, .write)
            } catch {
                // Not an answer about the method; the warrant reads too.
            }
        }
        return try await execute(contextId: contextId, method: method, argsJson: argsJson).returns
    }

    /// ``query(contextId:method:argsJson:)`` decoded into `T`.
    public func query<T: Decodable>(
        _ type: T.Type, contextId: String, method: String, argsJson: JSONValue = [:]
    ) async throws -> T {
        try decode(type, try await query(contextId: contextId, method: method, argsJson: argsJson))
    }

    /// ``execute(contextId:method:argsJson:)``'s `returns`, decoded into `T`.
    public func execute<T: Decodable>(
        _ type: T.Type, contextId: String, method: String, argsJson: JSONValue = [:]
    ) async throws -> T {
        try decode(type, try await execute(contextId: contextId, method: method, argsJson: argsJson).returns)
    }

    // MARK: - Nonce recovery

    /// Where this device stands in `contextId`'s nonce sequence, asked as the
    /// author (`POST /admin-api/contexts/{ctx}/warrant-nonce {authorProof}`).
    public func warrantNonce(contextId: String) async throws -> RelayWarrantNonceState {
        let url = try AccountHTTP.url(relayURL, "/admin-api/contexts/\(escape(contextId))/warrant-nonce")
        var headers: [String: String] = [:]
        if let token = await tokenProvider() { headers["Authorization"] = "Bearer \(token)" }
        let request = AccountHTTP.jsonRequest(
            url, method: "POST", body: ["authorProof": .string(authorProof)], headers: headers, timeout: timeout)
        let (raw, _) = try await AccountHTTP.sendRaw(request, session: session)
        return try RelayWarrantNonceState.parse(raw)
    }

    /// Advance the local sequence to where the node says it stands.
    public func recoverNonce(contextId: String) async throws {
        let state = try await warrantNonce(contextId: contextId)
        guard let next = state.nextNonce else {
            throw AccountError.intentRefused(
                reason: "this device has spent every nonce in context \(contextId); it must re-key to write again",
                retryable: false, status: 409)
        }
        nonces.advance(relay: relayURL, to: next)
    }

    // MARK: - Context creation

    public func describeCreation(groupId: String, author: String? = nil) async throws -> CreationDescription {
        let query = author.map { "?author=\(escape($0))" } ?? ""
        return try await data(
            CreationDescription.self, "GET", "/admin-api/groups/\(escape(groupId))/context-intents\(query)")
    }

    /// Create a context in `groupId` through the relay, as the account.
    public func createContext(
        groupId: String, applicationId: String, initArgs: JSONValue = [:], serviceName: String? = nil,
        name: String? = nil, seed: String? = nil
    ) async throws -> CreatedRelayContext {
        let described = try await describeCreation(groupId: groupId, author: authorAccount)
        guard described.canCreateOnBehalf else {
            throw AccountError.intentRefused(
                reason: "the relay (\(described.executorAccount)) has no standing to act for members of group "
                    + "\(described.groupId); an admin must grant it CAN_AUTHOR_ON_BEHALF (checked before signing — "
                    + "no nonce was spent)",
                retryable: false, status: 403)
        }
        if described.authorMayCreate == false {
            throw AccountError.intentRefused(
                reason: "the author (\(authorAccount)) may not create contexts in group \(described.groupId); it "
                    + "needs CAN_CREATE_CONTEXT or admin (checked before signing — no nonce was spent)",
                retryable: false, status: 403)
        }
        let executor = try checkedExecutor(described.executorAccount, described.executorKey)
        let (warrant, _) = try Warrants.signCreationWarrant(
            Warrants.CreationInput(
                group: groupId, seed: seed, authorAccount: authorAccount, executor: executor.account,
                executorKey: executor.key, applicationId: applicationId, serviceName: serviceName, name: name,
                initArgs: initArgs, nonce: nonces.next(relay: relayURL), notAfter: notAfter()),
            keys: keys)
        let body = try await json(
            "POST", "/admin-api/groups/\(escape(groupId))/context-intents",
            body: ["warrant": .string(warrant), "authorProof": .string(authorProof), "initArgs": initArgs])
        return try decode(CreatedRelayContext.self, body["data"])
    }

    // MARK: - Governance

    public func describeGovernance(groupId: String) async throws -> GovernanceDescription {
        try await data(GovernanceDescription.self, "GET", "/admin-api/groups/\(escape(groupId))/governance-intents")
    }

    /// Apply a governance op to `groupId` through the relay. Returns the group id.
    @discardableResult
    public func govern(groupId: String, op: Warrants.GovernanceOp) async throws -> String {
        let described = try await describeGovernance(groupId: groupId)
        guard described.canActOnBehalf else {
            throw AccountError.intentRefused(
                reason: "the relay (\(described.executorAccount)) has no standing to act for members of group "
                    + "\(described.groupId) (checked before signing, no nonce was spent)",
                retryable: false, status: 403)
        }
        let executor = try checkedExecutor(described.executorAccount, described.executorKey)
        let warrant = try Warrants.signGovernanceWarrant(
            Warrants.GovernanceInput(
                scope: groupId, op: op, authorAccount: authorAccount, executor: executor.account,
                executorKey: executor.key, nonce: governanceNonce(groupId), notAfter: notAfter()),
            keys: keys)
        let data = try await postGovernance(groupId: groupId, op: op, warrant: warrant)
        return data["groupId"]?.stringValue ?? groupId
    }

    /// Found a namespace through the relay, with the author as its founder,
    /// owner and admin. Port of mero-js `RelayClient.foundNamespace`.
    ///
    /// The author signs the exact genesis (``GovernanceOps/namespaceCreated(founder:credential:salt:)``)
    /// under a root-plane governance warrant scoped to the new id, which is
    /// derived from the author's account and the salt — so the relay can
    /// neither choose another id nor found it for anyone else. The relay is
    /// seated as the founding relay, so later ``govern(groupId:op:)``,
    /// ``createContext(groupId:applicationId:initArgs:serviceName:name:seed:)``
    /// and ``execute(contextId:method:argsJson:)`` work through it straight away.
    ///
    /// `application` and `defaultCapabilities` are set right after, each under
    /// its own warrant; a failure there is reported (`applicationSet: false`),
    /// not thrown, since the namespace exists. Both are validated before
    /// anything is signed.
    public func foundNamespace(
        executor: RelayExecutor, salt: String? = nil, defaultCapabilities: UInt32? = nil,
        application: FoundingApplication? = nil
    ) async throws -> FoundedNamespace {
        let executor = try checkedExecutor(executor.executorAccount, executor.executorKey)
        let salt =
            try salt.map { Hex.encode(try Hex.decode($0, label: "salt", bytes: 32)) } ?? Hex.encode(randomBytes(32))
        let namespaceId = try GovernanceOps.foundedNamespaceId(founder: authorAccount, salt: salt)
        let op = try GovernanceOps.namespaceCreated(founder: authorAccount, credential: authorProof, salt: salt)
        let capabilitiesOp = try defaultCapabilities.map { try GovernanceOps.defaultCapabilitiesSet($0) }
        let applicationOp = try application.map {
            try GovernanceOps.targetApplicationSet(
                applicationId: $0.applicationId, package: $0.package, version: $0.version)
        }

        let warrant = try Warrants.signGovernanceWarrant(
            Warrants.GovernanceInput(
                scope: namespaceId, op: op, authorAccount: authorAccount, executor: executor.account,
                executorKey: executor.key, nonce: governanceNonce(namespaceId), notAfter: notAfter()),
            keys: keys)
        let data = try await postGovernance(groupId: namespaceId, op: op, warrant: warrant)
        let teeError = data["teeError"]?.stringValue
        var founded = FoundedNamespace(
            namespaceId: data["groupId"]?.stringValue ?? namespaceId, salt: salt,
            teeEnabled: data["teeEnabled"]?.boolValue ?? false, teeError: teeError?.isEmpty == false ? teeError : nil)
        // The application first: without it the namespace can hold no context.
        if let applicationOp {
            do {
                try await govern(groupId: founded.namespaceId, op: applicationOp)
                founded.applicationSet = true
            } catch {
                founded.applicationSet = false
                founded.applicationError = Self.message(error)
            }
        }
        if let capabilitiesOp {
            do {
                try await govern(groupId: founded.namespaceId, op: capabilitiesOp)
                founded.defaultCapabilitiesSet = true
            } catch {
                founded.defaultCapabilitiesSet = false
                founded.defaultCapabilitiesError = Self.message(error)
            }
        }
        return founded
    }

    private func postGovernance(groupId: String, op: Warrants.GovernanceOp, warrant: String) async throws -> JSONValue {
        let body = try await json(
            "POST", "/admin-api/groups/\(escape(groupId))/governance-intents",
            body: [
                "warrant": .string(warrant), "authorProof": .string(authorProof),
                "op": .string(Hex.encode(op.bytes)),
            ])
        return body["data"] ?? .null
    }

    /// A governance warrant's nonce for `(relay, group)`: spent in a sliding
    /// per-(group, device) window, so it must never go backwards. Its own
    /// counter, floored at the clock (ms) so cleared storage resumes above
    /// anything spent before — as mero-js does.
    private func governanceNonce(_ groupId: String) -> UInt64 {
        let key = "\(relayURL)|governance|\(groupId.lowercased())"
        nonces.advance(relay: key, to: UInt64(Date().timeIntervalSince1970 * 1000))
        return nonces.next(relay: key)
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    // MARK: - Helpers

    private func notAfter() -> UInt64 {
        UInt64(Date().timeIntervalSince1970) + ttlSeconds
    }

    private func checkedExecutor(_ account: String, _ key: String) throws -> (account: String, key: String) {
        let account = Hex.encode(try Hex.decode(account, label: "the relay's executorAccount", bytes: 32))
        let key = Hex.encode(try Hex.decode(key, label: "the relay's executorKey", bytes: 32))
        if let executorAccount, executorAccount != account {
            throw AccountError.protocolViolation(
                "configured executorAccount \(executorAccount) is not the relay's account \(account); a warrant "
                    + "naming it would be unspendable")
        }
        return (account, key)
    }

    private func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?")))
            ?? segment
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) throws -> T {
        do {
            return try MeroJSON.decode(T.self, from: try MeroJSON.encode(value ?? .null))
        } catch {
            throw MeroError.decoding("relay response is not a \(T.self): \(error)")
        }
    }

    private func data<T: Decodable>(_ type: T.Type, _ method: String, _ path: String) async throws -> T {
        try decode(type, try await json(method, path, body: nil)["data"])
    }

    private func json(
        _ method: String, _ path: String, body: JSONValue?, bearer: String? = nil, refuseAsIntent: Bool = true
    ) async throws -> JSONValue {
        let url = try AccountHTTP.url(relayURL, path)
        var headers: [String: String] = [:]
        if let bearer { headers["Authorization"] = "Bearer \(bearer)" }
        let request = AccountHTTP.jsonRequest(url, method: method, body: body, headers: headers, timeout: timeout)
        var wait: UInt64 = 250_000_000
        var attempt = 0
        while true {
            do {
                return try await AccountHTTP.send(request, session: session)
            } catch MeroError.http(let http) where http.status == 429 && attempt < rateLimitRetries {
                attempt += 1
                let after = http.headers["retry-after"].flatMap { UInt64($0) }.map { $0 * 1_000_000_000 }
                try await Task.sleep(nanoseconds: after ?? wait)
                wait *= 2
            } catch MeroError.http(let http) where refuseAsIntent && (http.status == 400 || http.status == 403) {
                let reason = Self.extractReason(http.bodyText ?? "")
                throw AccountError.intentRefused(
                    reason: reason, retryable: reason.range(of: "nonce", options: .caseInsensitive) != nil,
                    status: http.status)
            }
        }
    }

    static func extractReason(_ body: String) -> String {
        guard !body.isEmpty else { return "no reason given" }
        if let parsed = try? MeroJSON.decode(JSONValue.self, from: Data(body.utf8)) {
            for candidate in [parsed["error"], parsed["message"]] {
                if let s = candidate?.stringValue, !s.isEmpty { return s }
            }
        }
        return body
    }
}

/// What the node said each `relay|context|method` is: a view (read) or not.
final class MethodKinds: @unchecked Sendable {
    enum Kind { case read, write }
    static let shared = MethodKinds()
    private let lock = NSLock()
    private var kinds: [String: Kind] = [:]

    func get(_ key: String) -> Kind? {
        lock.lock(); defer { lock.unlock() }
        return kinds[key]
    }

    func set(_ key: String, _ kind: Kind) {
        lock.lock(); defer { lock.unlock() }
        kinds[key] = kind
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        kinds.removeAll()
    }
}
