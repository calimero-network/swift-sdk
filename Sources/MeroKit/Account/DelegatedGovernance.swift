import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// An account's governance through the relay that serves its namespace:
// create a context, found a namespace, and the group ops a private context
// needs. Port of mero-js `src/account/create-context.ts` and `govern.ts`.
//
// A thin layer over ``RelayClient``'s `createContext` / `govern` /
// `foundNamespace`, adding what only this layer knows: which relay serves the
// namespace (the relay map) and the nonce bookkeeping. Nodes check the
// AUTHOR's rights (CAN_CREATE_CONTEXT, CAN_CREATE_SUBGROUP, MANAGE_MEMBERS…),
// never the relay's; the relay only needs standing to act.

/// What an account asks for when it creates a context: the fields of a node's
/// ``CreateContextRequest`` that have a place in the creation warrant, plus
/// which namespace to find the relay by. (== mero-js `CreateDelegatedContextRequest`.)
///
/// There is no `identitySecret`: the account IS the member identity (`init`
/// runs as the author's account), so there is nothing to derive one from.
public struct CreateDelegatedContextRequest: Sendable, Equatable {
    public var namespaceId: String
    /// The group to create it in; the namespace itself when `nil`.
    public var groupId: String?
    public var applicationId: String
    /// Which service of a multi-service bundle; `nil` for the default one.
    /// Signed into the warrant: the relay runs THAT service's `init`.
    public var serviceName: String?
    /// The seed the context id is derived from, 64 hex; random when `nil`.
    public var contextSeed: String?
    /// The `init` arguments as UTF-8 JSON bytes (a node request's shape).
    public var initializationParams: [Int]?
    public var name: String?

    public init(
        namespaceId: String, groupId: String? = nil, applicationId: String, serviceName: String? = nil,
        contextSeed: String? = nil, initializationParams: [Int]? = nil, name: String? = nil
    ) {
        self.namespaceId = namespaceId
        self.groupId = groupId
        self.applicationId = applicationId
        self.serviceName = serviceName
        self.contextSeed = contextSeed
        self.initializationParams = initializationParams
        self.name = name
    }
}

/// A private context and the restricted subgroup it lives in.
public struct DelegatedPrivateContext: Sendable, Equatable {
    public let contextId: String
    public let groupId: String
}

/// A warrant nonce store that hands out one fixed value: a creation warrant's
/// nonce is spent in the NEW context's window, which is empty until now.
private struct FixedWarrantNonce: WarrantNonceStore {
    let value: UInt64
    func next(relay: String) -> UInt64 { value }
    func advance(relay: String, to floor: UInt64) {}
}

extension DelegatedAccounts {
    // MARK: - Contexts

    /// Create a context through the relay that serves `request.namespaceId`,
    /// as the account. The creation warrant's nonce is `0` (the new context's
    /// window is empty), marked spent so its writes start above it; the relay
    /// is recorded as serving the namespace and the context.
    /// (== mero-js `createDelegatedContext`.)
    public static func createDelegatedContext(
        _ session: DelegatedSession, _ request: CreateDelegatedContextRequest,
        env: DelegatedEnvironment = DelegatedEnvironment()
    ) async throws -> CreatedRelayContext {
        let relay = try relayFor(session, namespaceId: request.namespaceId, store: env.store)
        let creationNonce: UInt64 = 0
        let client = relayClient(
            session, relayURL: relay, nonces: FixedWarrantNonce(value: creationNonce), env: env)
        let created = try await client.createContext(
            groupId: request.groupId ?? request.namespaceId, applicationId: request.applicationId,
            initArgs: try initArgs(request.initializationParams), serviceName: request.serviceName,
            name: request.name, seed: request.contextSeed)
        markContextNonceSpent(relayURL: relay, contextId: created.contextId, nonce: creationNonce, nonces: env.nonces)
        env.store.rememberRelay(
            account: session.account, relayURL: relay, namespaceId: request.namespaceId, contextId: created.contextId)
        return created
    }

    /// A context only the author and `members` are in (a DM, a small room): a
    /// restricted subgroup of the namespace (a root op, posted to the
    /// namespace), each member added to it directly — they are in the
    /// namespace already, so nobody is invited — and the context created in it.
    /// (== mero-js `createDelegatedPrivateContext`.)
    public static func createDelegatedPrivateContext(
        _ session: DelegatedSession, _ request: CreateDelegatedContextRequest, members: [String],
        env: DelegatedEnvironment = DelegatedEnvironment()
    ) async throws -> DelegatedPrivateContext {
        let namespaceId = request.namespaceId
        // The id is derived from a fresh salt (core#4244); a node refuses any other.
        let creation = try GovernanceOps.subgroupCreation(
            parentId: namespaceId, restricted: true, admin: session.account)
        let groupId = try await delegatedGovernance(
            session, namespaceId: namespaceId, group: namespaceId, op: creation.op, env: env)
        env.store.rememberGroupNamespace(account: session.account, groupId: groupId, namespaceId: namespaceId)
        for member in members {
            let added = try GovernanceOps.memberAdded(member, role: .member)
            try await delegatedGovernance(session, namespaceId: namespaceId, group: groupId, op: added, env: env)
        }
        var inGroup = request
        inGroup.groupId = groupId
        let created = try await createDelegatedContext(session, inGroup, env: env)
        return DelegatedPrivateContext(contextId: created.contextId, groupId: groupId)
    }

    // MARK: - Governance

    /// Publish one delegable governance op on `group` through the relay that
    /// serves `namespaceId`. Returns the group id the relay names.
    /// (== mero-js `delegatedGovernance`.)
    @discardableResult
    public static func delegatedGovernance(
        _ session: DelegatedSession, namespaceId: String, group: String, op: Warrants.GovernanceOp,
        env: DelegatedEnvironment = DelegatedEnvironment()
    ) async throws -> String {
        let relay = try relayFor(session, namespaceId: namespaceId, store: env.store)
        let client = relayClient(session, relayURL: relay, nonces: env.nonces, env: env)
        return try await client.govern(groupId: group, op: op)
    }

    /// A group op (member, role, capabilities, metadata, visibility, detach)
    /// on `groupId`, posted to the relay of its namespace. (== mero-js `governGroup`.)
    @discardableResult
    public static func governGroup(
        _ session: DelegatedSession, groupId: String, op: Warrants.GovernanceOp,
        env: DelegatedEnvironment = DelegatedEnvironment()
    ) async throws -> String {
        let namespaceId = try requireNamespace(session, groupId: groupId, store: env.store)
        return try await delegatedGovernance(session, namespaceId: namespaceId, group: groupId, op: op, env: env)
    }

    /// A root op (create, delete, move a subgroup; join an open one), posted
    /// to the NAMESPACE `groupId` belongs to. (== mero-js `governRoot`.)
    @discardableResult
    public static func governRoot(
        _ session: DelegatedSession, groupId: String, op: Warrants.GovernanceOp,
        env: DelegatedEnvironment = DelegatedEnvironment()
    ) async throws -> String {
        let namespaceId = try requireNamespace(session, groupId: groupId, store: env.store)
        return try await delegatedGovernance(session, namespaceId: namespaceId, group: namespaceId, op: op, env: env)
    }

    // MARK: - Founding

    /// Found a namespace as the account, through the first relay it knows.
    /// The account becomes founder, owner and admin; the relay is seated in it
    /// (a TEE relay admits itself as its first TEE), so contexts can be created
    /// through it straight away. (== mero-js `foundDelegatedNamespace`.)
    ///
    /// The relay's executor key is its node key **attested now** (never the pin
    /// alone: the founding relay holds the namespace's keys); its account is
    /// the session's when the session is on that relay, else the one discovery
    /// names on a namespace remembered there — only when discovery names that
    /// same key. With `application`, a namespace that could not be given it
    /// throws (no context could be created in it). HA is then asked for when
    /// the relay attested the founding; its outcome is reported in
    /// `haEnabled` / `haError`, never thrown.
    public static func foundDelegatedNamespace(
        _ session: DelegatedSession, defaultCapabilities: UInt32? = nil, application: FoundingApplication? = nil,
        env: DelegatedEnvironment = DelegatedEnvironment()
    ) async throws -> FoundedDelegatedNamespace {
        guard let relay = knownRelays(session, store: env.store).first else {
            throw AccountError.noRelay(method: "founding a namespace")
        }
        let executor = try await foundingExecutor(session, relay: relay, env: env)
        let client = relayClient(session, relayURL: relay, nonces: env.nonces, env: env)
        let founded = try await client.foundNamespace(
            executor: executor, defaultCapabilities: defaultCapabilities, application: application)
        env.store.rememberRelay(account: session.account, relayURL: relay, namespaceId: founded.namespaceId)
        if application != nil, founded.applicationSet != true {
            throw AccountError.intentRefused(
                reason: "founded \(founded.namespaceId) but could not give it its application: "
                    + (founded.applicationError ?? "unknown reason"),
                retryable: false, status: 409)
        }
        let ha: HaOutcome
        if founded.teeEnabled {
            ha = await enableHaBestEffort(
                session, namespaceId: founded.namespaceId, salt: founded.salt, relayURL: relay, env: env)
        } else {
            ha = HaOutcome(
                enabled: false,
                error: "the relay did not attest the founding, so no fleet node could be admitted for HA"
                    + (founded.teeError.map { ": \($0)" } ?? ""))
        }
        return FoundedDelegatedNamespace(
            namespaceId: founded.namespaceId, salt: founded.salt, teeEnabled: founded.teeEnabled,
            haEnabled: ha.enabled, haError: ha.error, defaultCapabilitiesSet: founded.defaultCapabilitiesSet)
    }

    /// The newest version of `package` the registry publishes that is not
    /// yanked. (== mero-js `latestPublishedVersion`.)
    public static func latestPublishedVersion(
        registryURL: String = ApplicationRegistry.defaultURL, package: String, session: URLSession = .shared
    ) async throws -> String {
        let bundles = try await ApplicationRegistry.bundles(
            registryURL: registryURL, package: package, session: session)
        guard let version = ApplicationRegistry.selectLatest(bundles)?.appVersion else {
            throw AccountError.invalidInput("the registry lists no version of \(package)")
        }
        return version
    }

    // MARK: - Helpers

    /// The relay that serves `namespaceId`: learned when the account joined
    /// or founded it, else the session's.
    static func relayFor(
        _ session: DelegatedSession, namespaceId: String, store: DelegatedAccountStore
    ) throws -> String {
        guard let url = store.relayMap(account: session.account).namespaces[namespaceId] ?? session.relayUrl else {
            throw AccountError.noRelay(method: "a call in namespace \(namespaceId)")
        }
        return relayOrigin(url)
    }

    static func requireNamespace(
        _ session: DelegatedSession, groupId: String, store: DelegatedAccountStore
    ) throws -> String {
        guard let namespaceId = namespaceOfGroup(session, groupId: groupId, store: store) else {
            throw AccountError.invalidInput(
                "the namespace of group \(groupId) is not known to this account: it can manage only groups in "
                    + "namespaces it joined or subgroups it created")
        }
        return namespaceId
    }

    /// A relay client for these calls: the author's credential and whatever
    /// nonces the call needs.
    static func relayClient(
        _ session: DelegatedSession, relayURL: String, nonces: any WarrantNonceStore, env: DelegatedEnvironment
    ) -> RelayClient {
        RelayClient(
            relayURL: relayURL, authorAccount: session.account, authorProof: session.credential, keys: session.keys,
            nonces: nonces, ttlSeconds: env.warrantTTLSeconds, session: env.urlSession, timeout: env.timeout)
    }

    /// The `init` arguments as the JSON the route takes, from the bytes a caller may hold.
    static func initArgs(_ params: [Int]?) throws -> JSONValue {
        guard let params, !params.isEmpty else { return [:] }
        guard params.allSatisfy({ (0...255).contains($0) }) else {
            throw AccountError.invalidInput("initializationParams must be bytes")
        }
        do {
            return try MeroJSON.decode(JSONValue.self, from: Data(params.map { UInt8($0) }))
        } catch {
            throw AccountError.invalidInput("initializationParams are not UTF-8 JSON: \(error)")
        }
    }

    /// The relay's attested node key, and its account.
    private static func foundingExecutor(
        _ session: DelegatedSession, relay: String, env: DelegatedEnvironment
    ) async throws -> RelayExecutor {
        if let named = session.executorAccount, let own = session.relayUrl, relayOrigin(own) == relay {
            return RelayExecutor(executorAccount: named, executorKey: try await attestedNodeKey(relay, env: env))
        }
        let map = env.store.relayMap(account: session.account)
        let onRelay = map.namespaces.keys.sorted().filter { map.namespaces[$0].map(relayOrigin) == relay }
        guard let known = onRelay.first else {
            throw AccountError.relayKeyUnavailable(
                "the executor account of this relay is not known: join a namespace on it first, or connect with the "
                    + "relay's executor account (the cloud shows it beside the relay)")
        }
        let executorKey = try await attestedNodeKey(relay, env: env)
        // Discovery is unauthenticated: it may name the account, never the key.
        let described = try await relayClient(session, relayURL: relay, nonces: env.nonces, env: env)
            .describeGovernance(groupId: known)
        guard described.executorKey.lowercased() == executorKey else {
            throw AccountError.relayKeyUnavailable(
                "the relay's discovery names signing key \(described.executorKey), not the relay's node key "
                    + "\(executorKey): refusing to found through it")
        }
        return RelayExecutor(executorAccount: described.executorAccount, executorKey: executorKey)
    }

    /// The relay's node key, attested now; any failed attestation throws.
    private static func attestedNodeKey(_ relay: String, env: DelegatedEnvironment) async throws -> String {
        switch await attemptRelayNodeKey(relay, fresh: true, env: env) {
        case .learned(let nodeKey):
            return nodeKey
        case .unavailable:
            throw AccountError.relayKeyUnavailable(
                "the relay's signing key could not be learned: its attestation did not answer, try again")
        case .refused:
            throw AccountError.relayKeyUnavailable(
                "the relay's attestation was refused, so founding through it is not possible: it is not a signed "
                    + "locked-read-only release")
        }
    }

    /// Whether the cloud agreed to host a founded namespace, and why not.
    struct HaOutcome: Sendable {
        let enabled: Bool
        let error: String?
    }

    /// Ask the cloud to host a namespace this account just founded, with no
    /// cloud session: the account proves it is the founder and the cloud bills
    /// the user it is linked to. Best-effort: a refusal is reported, never thrown.
    static func enableHaBestEffort(
        _ session: DelegatedSession, namespaceId: String, salt: String, relayURL: String, env: DelegatedEnvironment
    ) async -> HaOutcome {
        do {
            try await CloudClient(baseURL: env.cloudBaseURL, session: env.urlSession, timeout: env.timeout)
                .enableHaAsAccount(
                    namespaceId: namespaceId, salt: salt, accountId: session.account, credential: session.credential,
                    keys: session.keys, relayURL: relayURL)
            return HaOutcome(enabled: true, error: nil)
        } catch AccountError.haRefused(let code, _, let body) {
            guard let message = CloudClient.haRefusalMessages[code] else {
                let unknown = AccountError.haRefused(code: code, status: 0, body: body)
                return HaOutcome(enabled: false, error: unknown.errorDescription)
            }
            let blocking = code == HaRefusal.haRequestPending.code ? blockingNamespace(body) : nil
            return HaOutcome(enabled: false, error: blocking.map { "\(message) (waiting: \($0))" } ?? message)
        } catch {
            return HaOutcome(enabled: false, error: RelayClient.message(error))
        }
    }

    /// The namespace the cloud says is blocking, when it names one.
    static func blockingNamespace(_ body: String?) -> String? {
        guard let body, let json = try? MeroJSON.decode(JSONValue.self, from: Data(body.utf8)) else { return nil }
        let id = json["detail"]?["namespace_id"]?.stringValue ?? json["namespace_id"]?.stringValue
        guard let id, Hex.is32(id) else { return nil }
        return id.lowercased()
    }
}
