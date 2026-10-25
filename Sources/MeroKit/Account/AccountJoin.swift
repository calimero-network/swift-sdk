import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Signing a membership op and getting it admitted — how an account with no
/// node of its own joins a namespace from an invitation.
///
/// Port of mero-js `src/namespace-op/namespace-op.ts` and
/// `src/account/{join-with-node,bootstrap-from-invitation,relay-from-invitation}.ts`.
public enum NamespaceOps {
    /// core's `SIGNED_NAMESPACE_OP_SCHEMA_VERSION`: 27 since core 0.11.0
    /// (calimero-network/core#4625, no layout change from 26). A node refuses
    /// any other value.
    public static let schemaVersion: UInt8 = 27
    static let signDomain = "calimero.namespace.v1"
    static let opRoot: UInt8 = 0
    static let memberJoined: UInt8 = 5
    static let memberJoinedAt: UInt8 = 8

    /// Borsh `GroupInvitationFromAdmin`.
    public static func encodeGroupInvitation(_ body: GroupInvitationFromAdmin) throws -> Data {
        guard let role = body.invitedRole, (0...255).contains(role) else {
            throw AccountError.invalidInput("invitation has no invited_role")
        }
        var w = BorshWriter()
        w.raw(try bytes32(body.inviterIdentity, "inviter_identity"))
        w.raw(try bytes32(body.groupId, "group_id"))
        w.u64(UInt64(body.expirationTimestamp))
        w.raw(try bytes32(body.secretSalt, "secret_salt"))
        w.u8(UInt8(role))
        w.u32(UInt32(body.admitters.count))
        for (i, admitter) in body.admitters.enumerated() {
            w.raw(try Hex.decode(admitter, label: "admitters[\(i)]", bytes: 32))
        }
        return w.data
    }

    /// Borsh `SignedGroupOpenInvitation`, as it is re-encoded inside a join op.
    public static func encodeSignedInvitation(_ signed: SignedGroupOpenInvitation) throws -> Data {
        var w = BorshWriter()
        w.raw(try encodeGroupInvitation(signed.invitation))
        w.string(signed.inviterSignature)
        if let inviter = signed.inviterAccount, !inviter.isEmpty {
            w.u8(1)
            w.raw(try Hex.decode(inviter, label: "inviter_account", bytes: 32))
        } else {
            w.u8(0)
        }
        w.u32(UInt32(signed.admitterAddrs.count))
        signed.admitterAddrs.forEach { w.string($0) }
        try optionalBytes32(signed.applicationId, "application_id", into: &w)
        try optionalBytes32(signed.appKey, "app_key", into: &w)
        return w.data
    }

    /// The `signable` half of a member-join op (what is signed, after the domain).
    public static func memberJoinSignable(
        namespaceId: String, member: String, invitation: SignedGroupOpenInvitation, credential: String,
        signerPublicKey: Data, nonce: UInt64, joinedAt: UInt64, parentOpHashes: [String] = []
    ) throws -> Data {
        var op = BorshWriter()
        op.u8(opRoot)
        let expires = invitation.invitation.expirationTimestamp != 0
        op.u8(expires ? memberJoinedAt : memberJoined)
        op.raw(try Hex.decode(member, label: "member", bytes: 32))
        op.raw(try encodeSignedInvitation(invitation))
        if expires { op.u64(joinedAt) }
        op.raw(try Hex.decodeUnsized(credential, label: "credential"))

        var w = BorshWriter()
        w.u8(schemaVersion)
        w.raw(try Hex.decode(namespaceId, label: "namespaceId", bytes: 32))
        w.u32(UInt32(parentOpHashes.count))
        for (i, parent) in parentOpHashes.enumerated() {
            w.raw(try Hex.decode(parent, label: "parentOpHashes[\(i)]", bytes: 32))
        }
        w.raw(signerPublicKey)
        w.u64(nonce)
        w.raw(op.data)
        return w.data
    }

    /// Sign the op that admits `member` (the account) to `namespaceId`.
    ///
    /// Returns hex of `signable ‖ signature ‖ 0x00` (the trailing `0` is an
    /// empty endorsement). The signature is Ed25519 over `"calimero.namespace.v1" ‖ signable`
    /// — raw, not hashed.
    public static func signMemberJoinOp(
        namespaceId: String, member: String, invitation: SignedGroupOpenInvitation, credential: String,
        keys: DeviceKeys, nonce: UInt64, joinedAt: UInt64? = nil, parentOpHashes: [String] = []
    ) throws -> String {
        let signerPublicKey = try Ed25519.publicKey(seed: keys.signSecret)
        let signable = try memberJoinSignable(
            namespaceId: namespaceId, member: member, invitation: invitation, credential: credential,
            signerPublicKey: signerPublicKey, nonce: nonce,
            joinedAt: joinedAt ?? UInt64(Date().timeIntervalSince1970), parentOpHashes: parentOpHashes)
        let signature = try keys.sign(Data(signDomain.utf8) + signable)
        return Hex.encode(signable + signature + Data([0]))
    }

    private static func bytes32(_ value: [Int], _ label: String) throws -> Data {
        guard value.count == 32, value.allSatisfy({ (0...255).contains($0) }) else {
            throw AccountError.invalidInput("\(label) must be 32 bytes, got \(value.count)")
        }
        return Data(value.map { UInt8($0) })
    }

    private static func optionalBytes32(_ value: [Int]?, _ label: String, into w: inout BorshWriter) throws {
        guard let value else { return w.u8(0) }
        w.u8(1)
        w.raw(try bytes32(value, label))
    }
}

/// The relay a join was admitted through. (== mero-js `ResolvedInvitationRelay`.)
public struct InvitationRelay: Sendable, Equatable {
    /// The node origin to connect through.
    public let relayUrl: String
    /// Where the signed join is posted: the cloud's own, never rebuilt when given.
    public let admitUrl: String
    /// The admitter's account, as the cloud reported it.
    public let admitterAccount: String?
    /// Whether this node can also run delegated writes (`CAN_AUTHOR_ON_BEHALF`).
    /// `false` is not a failure of admission: the connection that follows
    /// reads and receives events but has its intents refused.
    public let writable: Bool
    /// Whether the attempt rests on advisory data (a lapsed heartbeat).
    public let stale: Bool
    /// The node's peer id, as the cloud reported it.
    public let peerId: String
}

/// The outcome of a join: whether the op reached the namespace topic, and the
/// relay to talk to afterwards.
public struct JoinOutcome: Sendable, Equatable {
    /// NOT "joined": membership lands when peers apply the op.
    public let published: Bool
    public let relayUrl: String
    /// How the node was chosen, when the cloud chose it; `nil` when the caller
    /// named the node itself.
    public let relay: InvitationRelay?
}

/// Which step of joining from an invitation could not be completed. Each one
/// needs a different action from the person, which is why this is an enum and
/// not a message. Raw values are mero-js's `BootstrapStep` strings.
public enum BootstrapStep: String, Sendable, Equatable, CaseIterable {
    /// The cloud read itself failed (offline, 5xx, a refused routing proof).
    /// Nothing is known about the namespace yet.
    case admittersLookup = "admitters-lookup"
    /// The cloud lists no node to admit through. An address on the invitation
    /// is not one: `admitter_addrs` is unsigned.
    case noNodes = "no-nodes"
    /// Nodes serve the namespace, and the invitation names none of them.
    /// Terminal for this invitation: ask for a fresh one.
    case notInvited = "not-invited"
    /// A named node exists but cannot take a join now. A wait.
    case invitedUnreachable = "invited-unreachable"
    /// A named node can admit but the cloud knows no address for it yet. A wait.
    case noRelayURL = "no-relay-url"
    /// The join op could not be signed; nothing was sent.
    case sign
    /// The node refused the join, or could not be reached.
    case admit
    /// This device holds no enrolled account, so there is nothing to admit.
    case noCredential = "no-credential"
}

/// A join from an invitation that did not happen, and why.
/// (== mero-js `BootstrapFailure` / `RelayResolutionFailure` / `JoinWithNodeFailure`.)
public struct BootstrapFailure: Error, Sendable, Equatable {
    public let step: BootstrapStep
    /// What to go and do about it.
    public let reason: String
    /// The HTTP status, when the failing step was an HTTP call that answered.
    public let status: Int?

    public init(step: BootstrapStep, reason: String, status: Int? = nil) {
        self.step = step
        self.reason = reason
        self.status = status
    }
}

extension BootstrapFailure: LocalizedError {
    public var errorDescription: String? { reason }
}

/// A relay to bootstrap through, or the step that stopped it.
public enum ResolveRelayResult: Sendable, Equatable {
    case resolved(InvitationRelay)
    case failed(BootstrapFailure)

    /// The relay, when one was resolved.
    public var relay: InvitationRelay? {
        if case .resolved(let relay) = self { return relay }
        return nil
    }

    /// The failure, when there was one.
    public var failure: BootstrapFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

/// What presenting a signed join to one node came to.
public enum JoinWithNodeResult: Sendable, Equatable {
    /// The node took the call: `published` says whether it published the op.
    case joined(published: Bool, relayUrl: String)
    case failed(BootstrapFailure)
}

/// What ``AccountJoin/bootstrapFromInvitation(namespaceId:invitation:account:credential:keys:nonce:nodeURL:cloud:session:)``
/// came to: a join to connect with, or the step that failed.
public enum BootstrapResult: Sendable, Equatable {
    case joined(JoinOutcome)
    case failed(BootstrapFailure)

    /// The join, when there was one.
    public var outcome: JoinOutcome? {
        if case .joined(let outcome) = self { return outcome }
        return nil
    }

    /// The failure, when there was one.
    public var failure: BootstrapFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    /// The join, or the failure thrown.
    public func get() throws -> JoinOutcome {
        switch self {
        case .joined(let outcome): return outcome
        case .failed(let failure): throw failure
        }
    }
}

/// Joining as an account (no node of its own). Port of mero-js
/// `relay-from-invitation.ts`, `join-with-node.ts` and
/// `bootstrap-from-invitation.ts`.
///
/// A node URL comes from the caller or from the cloud's routing for the
/// namespace, intersected with the invitation's signed `admitters` — never
/// from the invitation, signed or not: the inviter may be the attacker, and
/// `admitter_addrs` sits outside the inviter's signature.
public enum AccountJoin {
    /// Resolve a relay to bootstrap through, from an invitation and nothing
    /// else: the cloud's routing intersected with the signed `admitters` (an
    /// empty list is the legacy admission-by-broadcast shape). `canAdmit` and
    /// `servable` are advisory — a named node with an address is tried and the
    /// node decides; `stale` says the attempt rests on advisory data.
    /// (== mero-js `resolveRelayFromInvitation`.)
    public static func resolveRelayFromInvitation(
        namespaceId: String, admitters: [String],
        routing: @Sendable (String) async throws -> CloudNamespaceRouting
    ) async -> ResolveRelayResult {
        let found: CloudNamespaceRouting
        do {
            found = try await routing(namespaceId)
        } catch {
            return .failed(
                BootstrapFailure(
                    step: .admittersLookup,
                    reason: "The cloud could not be asked which nodes serve namespace \(namespaceId): "
                        + "\(RelayClient.message(error)). Nothing is known about the invitation yet — this is the "
                        + "lookup failing, not the invitation."))
        }
        guard !found.nodes.isEmpty else {
            return .failed(
                BootstrapFailure(
                    step: .noNodes,
                    reason: "The cloud lists no nodes serving this namespace, so there is no hosted node to be "
                        + "admitted through. The namespace has no fleet assignment — whoever invited you is running "
                        + "their own node, and admission has to go through a node the cloud routes to."))
        }
        let invited = Set(admitters.compactMap(normaliseAccount))
        let named = found.nodes.filter { node in
            invited.isEmpty || normaliseAccount(node.account).map(invited.contains) == true
        }
        guard !named.isEmpty else {
            let count = found.nodes.count
            return .failed(
                BootstrapFailure(
                    step: .notInvited,
                    reason: "\(count) node\(count == 1 ? "" : "s") serve this namespace, but your invitation names "
                        + "none of them. The signed admitter list is a snapshot from when the invitation was minted, "
                        + "so a node assigned since is healthy and will still refuse the claim. Ask for a fresh "
                        + "invitation."))
        }
        return chooseAdmitter(named, namespaceId: namespaceId, servable: found.servable)
    }

    /// ``resolveRelayFromInvitation(namespaceId:admitters:routing:)`` against `cloud`.
    public static func resolveRelayFromInvitation(
        namespaceId: String, admitters: [String], cloud: CloudClient
    ) async -> ResolveRelayResult {
        await resolveRelayFromInvitation(namespaceId: namespaceId, admitters: admitters) {
            try await cloud.getNamespaceRouting($0)
        }
    }

    /// Of the named nodes, one that can admit and has an address — preferring
    /// one that can also author, so one node serves both legs.
    private static func chooseAdmitter(
        _ named: [CloudNamespaceNode], namespaceId: String, servable: Bool
    ) -> ResolveRelayResult {
        let usable = named.filter(\.canAdmit)
        let candidates = usable.isEmpty ? named : usable
        let addressable = candidates.filter { ($0.relayUrl ?? "").isEmpty == false }
        guard
            let chosen = addressable.first(where: \.canExecute) ?? addressable.first(where: \.fresh)
                ?? addressable.first, let url = chosen.relayUrl
        else {
            return .failed(
                BootstrapFailure(
                    step: .noRelayURL,
                    reason: "A node your invitation names can admit you, but the cloud knows no address for it yet, "
                        + "so there would be nothing to connect through afterwards. Try again shortly."))
        }
        let relayUrl = DelegatedAccounts.relayOrigin(url)
        return .resolved(
            InvitationRelay(
                relayUrl: relayUrl, admitUrl: chosen.admitUrl ?? admitPath(relayUrl, namespaceId),
                admitterAccount: chosen.account, writable: chosen.canExecute,
                stale: !chosen.fresh || usable.isEmpty || !servable, peerId: chosen.peerId))
    }

    /// Pick the node to be admitted through, throwing the step that stopped it.
    public static func resolveRelay(
        namespaceId: String, invitation: SignedGroupOpenInvitation, cloud: CloudClient
    ) async throws -> InvitationRelay {
        let resolution = await resolveRelayFromInvitation(
            namespaceId: namespaceId, admitters: invitation.invitation.admitters, cloud: cloud)
        switch resolution {
        case .resolved(let relay): return relay
        case .failed(let failure): throw failure
        }
    }

    /// Sign the membership op with the device key and present it to ONE named
    /// node: `POST {admitURL ?? nodeURL/admin-api/namespaces/{ns}/admit}`
    /// `{invitation, signedOp}`, unauthenticated — the joiner's signature is
    /// the authorization. Never throws for an expected failure: a malformed op
    /// is final (`sign`), an unreachable node a retry and a refusal names its
    /// status (`admit`). (== mero-js `joinWithNode`.)
    public static func joinWithNode(
        nodeURL: String, admitURL: String? = nil, namespaceId: String, invitation: SignedGroupOpenInvitation,
        account: String, credential: String, keys: DeviceKeys, nonce: UInt64, session: URLSession = .shared
    ) async -> JoinWithNodeResult {
        let relayUrl = DelegatedAccounts.relayOrigin(nodeURL)
        let request: URLRequest
        do {
            let signedOp = try NamespaceOps.signMemberJoinOp(
                namespaceId: namespaceId, member: account, invitation: invitation, credential: credential, keys: keys,
                nonce: nonce)
            guard let url = URL(string: admitURL ?? admitPath(relayUrl, namespaceId)) else {
                throw AccountError.invalidInput("the admit URL is not a URL")
            }
            var built = URLRequest(url: url)
            built.httpMethod = "POST"
            built.timeoutInterval = 20
            built.setValue("application/json", forHTTPHeaderField: "Content-Type")
            built.setValue("application/json", forHTTPHeaderField: "Accept")
            built.httpBody = try MeroJSON.encode(AdmitJoinRequest(invitation: invitation, signedOp: signedOp))
            request = built
        } catch {
            return .failed(
                BootstrapFailure(
                    step: .sign,
                    reason: "The join op could not be signed, so nothing was sent: \(RelayClient.message(error))"))
        }
        do {
            let (data, _) = try await AccountHTTP.sendRaw(request, session: session)
            let body = try? MeroJSON.decode(JSONValue.self, from: data)
            // A 2xx this client cannot read is still a node that took the
            // call: reported as not published, which is exactly what is not known.
            return .joined(published: body?["data"]?["published"]?.boolValue == true, relayUrl: relayUrl)
        } catch MeroError.http(let http) {
            return .failed(
                BootstrapFailure(
                    step: .admit, reason: explainAdmitFailure(http.status, http.bodyText ?? ""), status: http.status))
        } catch {
            return .failed(
                BootstrapFailure(
                    step: .admit,
                    reason: "The admitter at \(nodeURL) could not be reached: \(RelayClient.message(error)). The "
                        + "invitation is untouched — this is the node being unreachable, not a refusal."))
        }
    }

    /// Sign the join and `POST` it to `admitURL`, throwing on failure: an
    /// ``AccountError/intentRefused(reason:retryable:status:)`` for a refusal,
    /// ``MeroError/network(_:)`` for an unreachable node,
    /// ``AccountError/invalidInput(_:)`` for an op that could not be signed.
    public static func joinWithNode(
        admitURL: URL, namespaceId: String, invitation: SignedGroupOpenInvitation, account: String,
        credential: String, keys: DeviceKeys, nonce: UInt64, session: URLSession = .shared
    ) async throws -> Bool {
        let base = admitURL.absoluteString
        let result = await joinWithNode(
            nodeURL: base, admitURL: base, namespaceId: namespaceId, invitation: invitation, account: account,
            credential: credential, keys: keys, nonce: nonce, session: session)
        switch result {
        case .joined(let published, _):
            return published
        case .failed(let failure):
            switch (failure.step, failure.status) {
            case (.admit, .some(let status)):
                throw AccountError.intentRefused(reason: failure.reason, retryable: false, status: status)
            case (.admit, .none):
                throw MeroError.network(failure.reason)
            default:
                throw AccountError.invalidInput(failure.reason)
            }
        }
    }

    /// Resolve the admitting relay (unless `nodeURL` names one — an
    /// operator's, a local rig's; never one from the invitation), then sign
    /// and send the join. Never throws: every failure comes back as the
    /// ``BootstrapStep`` it stopped at. (== mero-js `bootstrapFromInvitation`.)
    public static func bootstrapFromInvitation(
        namespaceId: String, invitation: SignedGroupOpenInvitation, account: String, credential: String,
        keys: DeviceKeys, nonce: UInt64, nodeURL: String? = nil, cloud: CloudClient, session: URLSession = .shared
    ) async -> BootstrapResult {
        var relay: InvitationRelay?
        var admitURL: String?
        let relayUrl: String
        if let nodeURL {
            relayUrl = DelegatedAccounts.relayOrigin(nodeURL)
        } else {
            // The signed list, read off the invitation itself: two sources for
            // one fact is how an intersection ends up against the wrong list.
            let resolution = await resolveRelayFromInvitation(
                namespaceId: namespaceId, admitters: invitation.invitation.admitters, cloud: cloud)
            switch resolution {
            case .failed(let failure):
                return .failed(failure)
            case .resolved(let resolved):
                relay = resolved
                relayUrl = resolved.relayUrl
                admitURL = resolved.admitUrl
            }
        }
        let joined = await joinWithNode(
            nodeURL: relayUrl, admitURL: admitURL, namespaceId: namespaceId, invitation: invitation, account: account,
            credential: credential, keys: keys, nonce: nonce, session: session)
        switch joined {
        case .failed(let failure):
            return .failed(failure)
        case .joined(let published, _):
            return .joined(JoinOutcome(published: published, relayUrl: relayUrl, relay: relay))
        }
    }

    static func admitPath(_ relayUrl: String, _ namespaceId: String) -> String {
        let segment =
            namespaceId.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?"))) ?? namespaceId
        return "\(DelegatedAccounts.relayOrigin(relayUrl))/admin-api/namespaces/\(segment)/admit"
    }

    static func normaliseAccount(_ account: String?) -> String? {
        guard let account else { return nil }
        var trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x") { trimmed.removeFirst(2) }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func explainAdmitFailure(_ status: Int, _ body: String) -> String {
        let detail = body.isEmpty ? "" : ": \(body)"
        switch status {
        case 400:
            return "The node refused the join as malformed (400)\(detail). The signature covers the invitation "
                + "exactly as sent, so an edited or re-serialised invitation fails here — as does a namespace id that "
                + "is not the invitation's own group."
        case 403:
            return "The node refused to carry this join (403)\(detail). Either it is not in the invitation's signed "
                + "admitters list — being live and listed by the cloud is not the same thing — or the invitation "
                + "itself was rejected as expired or not the inviter’s to issue."
        case 409:
            return "That node holds no device of its own, so it cannot endorse anyone (409)\(detail). Another "
                + "admitter from the same invitation would work."
        default:
            return "The join was not published (HTTP \(status))\(detail)."
        }
    }
}
