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
    /// core's `SIGNED_NAMESPACE_OP_SCHEMA_VERSION`.
    public static let schemaVersion: UInt8 = 24
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

/// The relay a join was admitted through.
public struct InvitationRelay: Sendable, Equatable {
    public let relayUrl: String
    public let admitUrl: String
    public let admitterAccount: String?
    public let writable: Bool
    public let stale: Bool
}

/// The outcome of a join: whether the op reached the namespace topic, and the
/// relay to talk to afterwards.
public struct JoinOutcome: Sendable, Equatable {
    /// NOT "joined": membership lands when peers apply the op.
    public let published: Bool
    public let relayUrl: String
    public let relay: InvitationRelay?
}

/// Joining as an account (no node of its own).
public enum AccountJoin {
    /// Pick the node to be admitted through: the cloud's routing intersected
    /// with the invitation's signed `admitters`, else an http(s) admitter
    /// address from the invitation itself.
    public static func resolveRelay(
        namespaceId: String, invitation: SignedGroupOpenInvitation, cloud: CloudClient
    ) async throws -> InvitationRelay {
        let routing = try await cloud.getNamespaceRouting(namespaceId)
        let invited = Set(invitation.invitation.admitters.compactMap(normaliseAccount))

        if routing.nodes.isEmpty {
            let httpAddrs = invitation.admitterAddrs.filter { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
            if var relayUrl = httpAddrs.first {
                while relayUrl.hasSuffix("/") { relayUrl.removeLast() }
                return InvitationRelay(
                    relayUrl: relayUrl, admitUrl: "\(relayUrl)/admin-api/namespaces/\(namespaceId)/admit",
                    admitterAccount: invited.count == 1 ? invited.first : nil, writable: true, stale: false)
            }
            throw AccountError.notSignedIn(
                "The cloud lists no nodes serving this namespace, so there is no hosted node to be admitted through.")
        }

        let named = routing.nodes.filter { node in
            invited.isEmpty || normaliseAccount(node.account).map(invited.contains) == true
        }
        guard !named.isEmpty else {
            throw AccountError.notSignedIn(
                "\(routing.nodes.count) node(s) serve this namespace, but your invitation names none of them. "
                    + "Ask for a fresh invitation.")
        }
        let usable = named.filter(\.canAdmit)
        let candidates = usable.isEmpty ? named : usable
        let addressable = candidates.filter { ($0.relayUrl ?? "").isEmpty == false }
        guard
            let chosen = addressable.first(where: \.canExecute) ?? addressable.first(where: \.fresh)
                ?? addressable.first, var relayUrl = chosen.relayUrl
        else {
            throw AccountError.notSignedIn(
                "A node your invitation names can admit you, but the cloud knows no address for it yet. Try again shortly."
            )
        }
        while relayUrl.hasSuffix("/") { relayUrl.removeLast() }
        return InvitationRelay(
            relayUrl: relayUrl,
            admitUrl: chosen.admitUrl ?? "\(relayUrl)/admin-api/namespaces/\(namespaceId)/admit",
            admitterAccount: chosen.account, writable: chosen.canExecute,
            stale: !chosen.fresh || usable.isEmpty || !routing.servable)
    }

    /// Sign the join and `POST` it to `admitURL` (`/admin-api/namespaces/{ns}/admit`).
    public static func joinWithNode(
        admitURL: URL, namespaceId: String, invitation: SignedGroupOpenInvitation, account: String,
        credential: String, keys: DeviceKeys, nonce: UInt64, session: URLSession = .shared
    ) async throws -> Bool {
        let signedOp = try NamespaceOps.signMemberJoinOp(
            namespaceId: namespaceId, member: account, invitation: invitation, credential: credential, keys: keys,
            nonce: nonce)
        var request = URLRequest(url: admitURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try MeroJSON.encode(AdmitJoinRequest(invitation: invitation, signedOp: signedOp))
        do {
            let (data, _) = try await AccountHTTP.sendRaw(request, session: session)
            let body = try? MeroJSON.decode(JSONValue.self, from: data)
            return body?["data"]?["published"]?.boolValue == true
        } catch MeroError.http(let http) {
            throw AccountError.intentRefused(
                reason: explainAdmitFailure(http.status, http.bodyText ?? ""), retryable: false, status: http.status)
        }
    }

    /// Resolve the admitting relay (unless `nodeURL` names one), then sign and
    /// send the join.
    public static func bootstrapFromInvitation(
        namespaceId: String, invitation: SignedGroupOpenInvitation, account: String, credential: String,
        keys: DeviceKeys, nonce: UInt64, nodeURL: String? = nil, cloud: CloudClient, session: URLSession = .shared
    ) async throws -> JoinOutcome {
        var relay: InvitationRelay?
        let admitURL: URL
        let relayUrl: String
        if var nodeURL {
            while nodeURL.hasSuffix("/") { nodeURL.removeLast() }
            relayUrl = nodeURL
            admitURL = try AccountHTTP.url(nodeURL, "/admin-api/namespaces/\(namespaceId)/admit")
        } else {
            let resolved = try await resolveRelay(namespaceId: namespaceId, invitation: invitation, cloud: cloud)
            relay = resolved
            relayUrl = resolved.relayUrl
            guard let url = URL(string: resolved.admitUrl) else {
                throw AccountError.protocolViolation("the cloud named an admit URL that is not a URL")
            }
            admitURL = url
        }
        let published = try await joinWithNode(
            admitURL: admitURL, namespaceId: namespaceId, invitation: invitation, account: account,
            credential: credential, keys: keys, nonce: nonce, session: session)
        return JoinOutcome(published: published, relayUrl: relayUrl, relay: relay)
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
            return "The node refused the join as malformed (400)\(detail). An edited or re-serialised invitation "
                + "fails here, as does a namespace id that is not the invitation's own group."
        case 403:
            return "The node refused to carry this join (403)\(detail). Either it is not in the invitation's signed "
                + "admitters list, or the invitation was rejected as expired."
        case 409:
            return "That node holds no device of its own, so it cannot endorse anyone (409)\(detail). Another "
                + "admitter from the same invitation would work."
        default:
            return "The join was not published (HTTP \(status))\(detail)."
        }
    }
}
