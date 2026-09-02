// Admin API types for the surface core added between 0.11.0-rc.26 and rc.29:
// the node's own identity, an application's ABI, warrant-authorised intents,
// direct admission, group member devices, and everything account-scoped
// (devices, applications, pairing, relink, revoke).
//
// Split out of AdminTypes.swift, which is the 1:1 port of mero-js's
// admin-types.ts and had grown past what one file should hold. Same wire rules
// apply: core serialises these with `#[serde(rename_all = "camelCase")]`, so
// the Swift property names map 1:1 and the default coder round-trips them.
//
// ⚠️ Three of these endpoints return their payload FLAT rather than under
// `data` — see AccountDevicesResponse, AccountApplicationsResponse and
// ListMemberDevicesResponseData. That is not guessable from the others; the
// fixtures in Tests/MeroKitTests/Fixtures are captured from a live node for
// exactly that reason.

import Foundation

// MARK: - Node identity, application ABI, intents  (core 0.11.0-rc.26 … rc.29)

/// An application's ABI, as `cargo mero build` emitted it.
///
/// Left as arbitrary JSON on purpose: the ABI's own schema is the contract
/// author's, not the SDK's, and modelling it here would date on every
/// `#[app::logic]` feature core adds.
public typealias ApplicationAbi = JSONValue

/// A state change authorised by a warrant rather than by the caller's own
/// membership — the route a keyholder with no node of its own writes through.
public struct PerformIntentRequest: Codable, Sendable {
    public var method: String
    public var argsJson: JSONValue
    /// The signed warrant naming what the author may do.
    public var warrant: String
    /// The author's signature over the intent.
    public var authorProof: String
    public init(method: String, argsJson: JSONValue, warrant: String, authorProof: String) {
        self.method = method; self.argsJson = argsJson
        self.warrant = warrant; self.authorProof = authorProof
    }
}

public struct PerformIntentResponseData: Codable, Sendable {
    public let rootHash: String
    public let returns: JSONValue?
    public init(rootHash: String, returns: JSONValue? = nil) {
        self.rootHash = rootHash; self.returns = returns
    }
}

// MARK: - Direct admission  (core 0.11.0-rc.29)

/// A join the joiner signed but cannot publish, handed to a node the inviter
/// named in the invitation's `admitters`.
///
/// The case it exists for: a joiner that holds an account and a key and no node
/// at all, so it has nowhere to publish its membership op from. The alternative
/// — announcing on the namespace topic and waiting for any ready peer — staples
/// the whole invitation to a beacon that goes out as plain borsh to every
/// subscriber.
public struct AdmitJoinRequest: Codable, Sendable {
    /// The invitation being claimed. It must name this node in its `admitters`,
    /// and must otherwise verify: being designated is permission to carry a
    /// valid claim, not to skip checking it.
    public var invitation: SignedGroupOpenInvitation
    /// The joiner's `SignedNamespaceOp`, borsh-encoded and hex.
    ///
    /// Signed by the joiner's DEVICE key, and every peer checks that when it
    /// applies the join — so an admitter can carry this and cannot author it,
    /// alter who joined, which group, or with what role.
    public var signedOp: String
    public init(invitation: SignedGroupOpenInvitation, signedOp: String) {
        self.invitation = invitation; self.signedOp = signedOp
    }
}

public struct AdmitJoinResponseData: Codable, Sendable {
    /// Whether the op reached the namespace topic.
    ///
    /// NOT "joined": membership lands when peers apply the op, which the
    /// admitting node neither performs nor waits for.
    public let published: Bool
    public init(published: Bool) { self.published = published }
}

// MARK: - Group member devices  (core 0.11.0-rc.26)

/// One device belonging to a member account.
public struct MemberDeviceEntry: Codable, Sendable {
    public let deviceId: String
    public let signingKey: String
    public init(deviceId: String, signingKey: String) {
        self.deviceId = deviceId; self.signingKey = signingKey
    }
}

/// A member account and the devices it holds.
///
/// The listing that makes the account/device distinction usable: group
/// membership is keyed by `account`, while what signs is a device. Since rc.27
/// both are 64 hex characters, so this mapping is the only thing that tells
/// them apart — and `addGroupMembers` takes a DEVICE key while
/// `removeGroupMembers` and every role grant take the ACCOUNT.
public struct MemberDevicesEntry: Codable, Sendable {
    public let account: String
    public let devices: [MemberDeviceEntry]
    public init(account: String, devices: [MemberDeviceEntry]) {
        self.account = account; self.devices = devices
    }
}

public struct ListMemberDevicesResponseData: Codable, Sendable {
    public let members: [MemberDevicesEntry]
    public init(members: [MemberDevicesEntry]) { self.members = members }
}

// MARK: - Account: devices, applications, pairing, relink, revoke
//         (core 0.11.0-rc.26 … rc.28; the routes moved from
//          /namespaces/{id}/account/* to /account/*)

public struct AccountDeviceEntry: Codable, Sendable {
    public let deviceId: String
    public let signingKey: String
    /// True for the device this node itself holds.
    public let isSelf: Bool
    public let revoked: Bool
    public let applications: [String]
    public let namespaces: [String]
    public init(
        deviceId: String, signingKey: String, isSelf: Bool, revoked: Bool,
        applications: [String], namespaces: [String]
    ) {
        self.deviceId = deviceId; self.signingKey = signingKey; self.isSelf = isSelf
        self.revoked = revoked; self.applications = applications; self.namespaces = namespaces
    }
}

/// NOTE: core returns this one FLAT (`{ devices: [...] }`), not under `data`.
public struct AccountDevicesResponse: Codable, Sendable {
    public let devices: [AccountDeviceEntry]
    public init(devices: [AccountDeviceEntry]) { self.devices = devices }
}

public struct AccountApplicationEntry: Codable, Sendable {
    public let applicationId: String
    public let namespaces: [String]
    public init(applicationId: String, namespaces: [String]) {
        self.applicationId = applicationId; self.namespaces = namespaces
    }
}

/// NOTE: flat (`{ applications: [...] }`), like ``AccountDevicesResponse``.
public struct AccountApplicationsResponse: Codable, Sendable {
    public let applications: [AccountApplicationEntry]
    public init(applications: [AccountApplicationEntry]) { self.applications = applications }
}

public struct AccountPairInitRequest: Codable, Sendable {
    public var accountRootPublicKey: String
    /// The namespaces the new device should be linked into.
    public var namespaces: [String]
    public init(accountRootPublicKey: String, namespaces: [String] = []) {
        self.accountRootPublicKey = accountRootPublicKey; self.namespaces = namespaces
    }
}

public struct PairDeviceInitResponseData: Codable, Sendable {
    public let accountId: String
    public let deviceId: String
    public let kemPublicKey: String
    public let signPublicKey: String
    public let statement: String
    /// Show this to the person on both devices; it is what makes the pairing
    /// something they can check rather than something they must trust.
    public let confirmationCode: String
    public init(
        accountId: String, deviceId: String, kemPublicKey: String, signPublicKey: String,
        statement: String, confirmationCode: String
    ) {
        self.accountId = accountId; self.deviceId = deviceId
        self.kemPublicKey = kemPublicKey; self.signPublicKey = signPublicKey
        self.statement = statement; self.confirmationCode = confirmationCode
    }
}

public struct AccountPairCompleteRequest: Codable, Sendable {
    public var deviceId: String
    public var kemPublicKey: String
    public var signPublicKey: String
    public var statement: String
    public var confirmationCode: String
    public var applications: [String]
    public init(
        deviceId: String, kemPublicKey: String, signPublicKey: String, statement: String,
        confirmationCode: String, applications: [String] = []
    ) {
        self.deviceId = deviceId; self.kemPublicKey = kemPublicKey
        self.signPublicKey = signPublicKey; self.statement = statement
        self.confirmationCode = confirmationCode; self.applications = applications
    }
}

public struct PairDeviceCompleteResponseData: Codable, Sendable {
    public let accountId: String
    public let deviceId: String
    public let keyDelivered: Bool
    public let confirmationCode: String
    /// The device certificate the new device signs with.
    public let credential: String
    public init(
        accountId: String, deviceId: String, keyDelivered: Bool, confirmationCode: String,
        credential: String
    ) {
        self.accountId = accountId; self.deviceId = deviceId
        self.keyDelivered = keyDelivered; self.confirmationCode = confirmationCode
        self.credential = credential
    }
}

public struct RelinkDeviceRequest: Codable, Sendable {
    public var applications: [String]
    public init(applications: [String] = []) { self.applications = applications }
}

public struct RelinkOutcomeEntry: Codable, Sendable {
    public let namespaceId: String
    public let keyDelivered: Bool
    public init(namespaceId: String, keyDelivered: Bool) {
        self.namespaceId = namespaceId; self.keyDelivered = keyDelivered
    }
}

public struct RelinkSkipEntry: Codable, Sendable {
    public let namespaceId: String
    public let reason: String
    public init(namespaceId: String, reason: String) {
        self.namespaceId = namespaceId; self.reason = reason
    }
}

public struct RelinkDeviceResponseData: Codable, Sendable {
    public let accountId: String
    public let deviceId: String
    public let applications: [String]
    public let linkedIn: [RelinkOutcomeEntry]
    /// Namespaces the relink deliberately did not touch, each with why.
    public let skipped: [RelinkSkipEntry]
    public init(
        accountId: String, deviceId: String, applications: [String],
        linkedIn: [RelinkOutcomeEntry], skipped: [RelinkSkipEntry]
    ) {
        self.accountId = accountId; self.deviceId = deviceId
        self.applications = applications; self.linkedIn = linkedIn; self.skipped = skipped
    }
}

public struct RevokeDeviceRequest: Codable, Sendable {
    public var deviceId: String
    public var proof: String?
    public init(deviceId: String, proof: String? = nil) {
        self.deviceId = deviceId; self.proof = proof
    }
}

public struct RevocationOutcomeEntry: Codable, Sendable {
    public let namespaceId: String
    public let keyRotated: Bool
    public init(namespaceId: String, keyRotated: Bool) {
        self.namespaceId = namespaceId; self.keyRotated = keyRotated
    }
}

public struct RevokeDeviceResponseData: Codable, Sendable {
    public let accountId: String
    public let deviceId: String
    public let keyRotated: Bool
    public let revokedIn: [RevocationOutcomeEntry]
    public init(
        accountId: String, deviceId: String, keyRotated: Bool,
        revokedIn: [RevocationOutcomeEntry]
    ) {
        self.accountId = accountId; self.deviceId = deviceId
        self.keyRotated = keyRotated; self.revokedIn = revokedIn
    }
}
