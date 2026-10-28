import Foundation

/// An invitation as the Calimero web apps share it, so a native app redeems a
/// link minted on the web and mints one the web redeems.
/// (== Kotlin `com.calimero.mero.invite.AppInvitation`.)
///
/// The token is ``InviteCodec``'s `base58(deflate(JSON))`; the JSON is the
/// signed invitation wrapped with the namespace's name, under a key each web
/// app picks:
///
/// - mero-design: `{"invitation": <signed>, "__teamName": "…"}` (the node's
///   `createNamespaceInvitation` data, plus the name)
/// - mero-chat and the others: `{"invitation": <signed>, "groupName" | "groupAlias": "…"}`
///
/// Decoding takes every shape they send: the wrapped payload or a bare signed
/// invitation, under an optional `data` envelope, with the signature under
/// `inviter_signature` or `inviterSignature`, and the name under any of
/// ``nameKeys``. A link, a `calimero://` link or a bare token all work
/// (``parse(_:expectedSlug:)``).
public struct AppInvitation: Sendable {
    /// What the name is read from, first match wins.
    public static let nameKeys = ["groupName", "groupAlias", "__teamName", "teamName", "name"]
    /// What ``token(nameKey:)`` writes the name under unless told otherwise.
    public static let defaultNameKey = "groupName"

    /// The signed invitation: what ``MeroAppBackend/joinNamespace(namespaceId:invitation:)`` redeems.
    public let invitation: SignedGroupOpenInvitation
    /// The namespace's name, as the inviter shared it.
    public let name: String?

    public init(invitation: SignedGroupOpenInvitation, name: String? = nil) {
        self.invitation = invitation
        self.name = name
    }

    /// The namespace the invitation admits to: the hex of its signed `group_id`.
    public var namespaceId: String {
        Hex.encode(invitation.invitation.groupId.map { UInt8(truncatingIfNeeded: $0) })
    }

    // MARK: Encoding

    /// The shareable token: `base58(deflate({"invitation": …, nameKey: name}))`.
    /// Pass the key the app's web build reads (`__teamName` for mero-design).
    public func token(nameKey: String = AppInvitation.defaultNameKey) throws -> String {
        var payload: [String: JSONValue] = [
            "invitation": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(invitation))
        ]
        if let name { payload[nameKey] = .string(name) }
        let json = String(decoding: CanonicalJSON.data(.object(payload)), as: UTF8.self)
        guard let token = InviteCodec.encode(json: json) else {
            throw MeroError.decoding("could not encode invitation payload")
        }
        return token
    }

    /// The shareable link for ``token(nameKey:)`` (``InviteLink/invitation(token:slug:host:)``).
    public func link(
        slug: String, nameKey: String = AppInvitation.defaultNameKey, host: String = InviteLink.defaultHost
    ) throws -> String {
        InviteLink.invitation(token: try token(nameKey: nameKey), slug: slug, host: host)
    }

    // MARK: Decoding

    /// Parse a pasted or opened link, a `calimero://` link or a bare token.
    /// `nil` when nothing in it is an invitation, or when it is a link for an
    /// app other than `expectedSlug` (redeeming it would join that app's namespace).
    public static func parse(_ input: String, expectedSlug: String? = nil) -> AppInvitation? {
        guard let token = InviteLink.token(fromPasted: input, expectedSlug: expectedSlug) else { return nil }
        return decode(token: token)
    }

    /// Decode a token (any form ``InviteCodec/decode(token:)`` reads).
    public static func decode(token: String) -> AppInvitation? {
        guard let json = InviteCodec.decode(token: token) else { return nil }
        return decode(json: json)
    }

    /// Decode the payload JSON.
    public static func decode(json: String) -> AppInvitation? {
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return nil }
        let inner = parsed["data"] ?? parsed
        if let wrapped = inner["invitation"], isSigned(wrapped), let signed = signed(wrapped) {
            let name = nameKeys.lazy.compactMap { inner[$0]?.stringValue }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return AppInvitation(invitation: signed, name: name)
        }
        if isSigned(inner), let signed = signed(inner) {
            return AppInvitation(invitation: signed)
        }
        return nil
    }

    /// A signature and an inner invitation object (the web apps' `isSignedGroupOpenInvitation`).
    private static func isSigned(_ value: JSONValue) -> Bool {
        guard case .object(let fields) = value, case .object? = fields["invitation"] else { return false }
        return fields["inviter_signature"]?.stringValue != nil || fields["inviterSignature"]?.stringValue != nil
    }

    private static func signed(_ value: JSONValue) -> SignedGroupOpenInvitation? {
        guard case .object(var fields) = value else { return nil }
        if fields["inviter_signature"] == nil, let camel = fields["inviterSignature"] {
            fields["inviter_signature"] = camel
            fields["inviterSignature"] = nil
        }
        guard let data = try? JSONEncoder().encode(JSONValue.object(fields)),
            let signed = try? JSONDecoder().decode(SignedGroupOpenInvitation.self, from: data),
            signed.invitation.groupId.count == 32
        else { return nil }
        return signed
    }
}
