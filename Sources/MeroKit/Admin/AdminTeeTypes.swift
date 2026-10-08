// TEE admin types: node attestation, and the per-group TEE admission policy.

import Foundation

// MARK: - TEE

public struct TeeInfoResponseData: Codable, Sendable {
    public let cloudProvider: String
    public let osImage: String
    public let mrtd: String
    public init(cloudProvider: String, osImage: String, mrtd: String) {
        self.cloudProvider = cloudProvider; self.osImage = osImage; self.mrtd = mrtd
    }
}

public struct TeeAttestRequest: Codable, Sendable {
    public var nonce: String
    public var applicationId: String?
    /// Bind this node's signing key into the quote's report data; the answer
    /// then carries ``TeeAttestResponseData/boundPublicKey``. New in rc.83.
    public var bindNodeKey: Bool
    /// Bind the sealed-transport key into the quote; the answer then carries
    /// ``TeeAttestResponseData/transportPublicKey``. New in rc.83.
    public var bindTransportKey: Bool
    /// Return the DCAP collateral needed to verify the quote offline, as
    /// ``TeeAttestResponseData/collateral``. New in rc.83.
    public var includeCollateral: Bool
    public init(
        nonce: String, applicationId: String? = nil, bindNodeKey: Bool = false,
        bindTransportKey: Bool = false, includeCollateral: Bool = false
    ) {
        self.nonce = nonce; self.applicationId = applicationId; self.bindNodeKey = bindNodeKey
        self.bindTransportKey = bindTransportKey; self.includeCollateral = includeCollateral
    }

    // The flags are sent only when set, so an unflagged request is the exact
    // body an older node (`deny_unknown_fields`) accepts.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nonce, forKey: .nonce)
        try c.encodeIfPresent(applicationId, forKey: .applicationId)
        if bindNodeKey { try c.encode(true, forKey: .bindNodeKey) }
        if bindTransportKey { try c.encode(true, forKey: .bindTransportKey) }
        if includeCollateral { try c.encode(true, forKey: .includeCollateral) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nonce = try c.decode(String.self, forKey: .nonce)
        applicationId = try c.decodeIfPresent(String.self, forKey: .applicationId)
        bindNodeKey = try c.decodeIfPresent(Bool.self, forKey: .bindNodeKey) ?? false
        bindTransportKey = try c.decodeIfPresent(Bool.self, forKey: .bindTransportKey) ?? false
        includeCollateral = try c.decodeIfPresent(Bool.self, forKey: .includeCollateral) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case nonce, applicationId, bindNodeKey, bindTransportKey, includeCollateral
    }
}

/// Body for `POST /tee/registration-attest`. New in core rc.83.
public struct TeeRegistrationAttestRequest: Codable, Sendable {
    /// Hex, 32 bytes.
    public var nonce: String
    public init(nonce: String) { self.nonce = nonce }
}

public struct QuoteHeader: Codable, Sendable {
    public let version: Int
    public let attestationKeyType: Int
    public let teeType: Int
    public let qeVendorId: String
    public let userData: String
    public init(version: Int, attestationKeyType: Int, teeType: Int, qeVendorId: String, userData: String) {
        self.version = version; self.attestationKeyType = attestationKeyType; self.teeType = teeType
        self.qeVendorId = qeVendorId; self.userData = userData
    }
}

public struct QuoteBody: Codable, Sendable {
    public let tdxVersion: String
    public let teeTcbSvn: String
    public let mrseam: String
    public let mrsignerseam: String
    public let seamattributes: String
    public let tdattributes: String
    public let xfam: String
    public let mrtd: String
    public let mrconfigid: String
    public let mrowner: String
    public let mrownerconfig: String
    public let rtmr0: String
    public let rtmr1: String
    public let rtmr2: String
    public let rtmr3: String
    public let reportdata: String
    public let teeTcbSvn2: String?
    public let mrservicetd: String?
    public init(
        tdxVersion: String, teeTcbSvn: String, mrseam: String, mrsignerseam: String, seamattributes: String,
        tdattributes: String, xfam: String, mrtd: String, mrconfigid: String, mrowner: String,
        mrownerconfig: String, rtmr0: String, rtmr1: String, rtmr2: String, rtmr3: String, reportdata: String,
        teeTcbSvn2: String? = nil, mrservicetd: String? = nil
    ) {
        self.tdxVersion = tdxVersion; self.teeTcbSvn = teeTcbSvn; self.mrseam = mrseam; self.mrsignerseam = mrsignerseam
        self.seamattributes = seamattributes; self.tdattributes = tdattributes; self.xfam = xfam; self.mrtd = mrtd
        self.mrconfigid = mrconfigid; self.mrowner = mrowner; self.mrownerconfig = mrownerconfig
        self.rtmr0 = rtmr0; self.rtmr1 = rtmr1; self.rtmr2 = rtmr2; self.rtmr3 = rtmr3; self.reportdata = reportdata
        self.teeTcbSvn2 = teeTcbSvn2; self.mrservicetd = mrservicetd
    }
}

public struct Quote: Codable, Sendable {
    public let header: QuoteHeader
    public let body: QuoteBody
    public let signature: String
    public let attestationKey: String
    /// `unknown` in the TS — arbitrary JSON. Modeled optional to tolerate omission.
    public let certificationData: JSONValue?
    public init(
        header: QuoteHeader, body: QuoteBody, signature: String, attestationKey: String,
        certificationData: JSONValue? = nil
    ) {
        self.header = header; self.body = body; self.signature = signature
        self.attestationKey = attestationKey; self.certificationData = certificationData
    }
}

public struct TeeAttestResponseData: Codable, Sendable {
    public let quoteB64: String
    public let quote: Quote
    /// The node signing key bound into the quote, when `bindNodeKey` was set.
    public let boundPublicKey: String?
    /// The sealed-transport public key bound into the quote, when
    /// `bindTransportKey` was set.
    public let transportPublicKey: String?
    /// DCAP collateral for offline quote verification, when
    /// `includeCollateral` was set. Kept as raw JSON.
    public let collateral: JSONValue?
    public init(
        quoteB64: String, quote: Quote, boundPublicKey: String? = nil,
        transportPublicKey: String? = nil, collateral: JSONValue? = nil
    ) {
        self.quoteB64 = quoteB64; self.quote = quote; self.boundPublicKey = boundPublicKey
        self.transportPublicKey = transportPublicKey; self.collateral = collateral
    }
}

// MARK: - TEE admission policy

/// What a TEE admitted under a policy may do: hold a full replica, or act
/// only as a relay. Sent lowercase. Core's default is `replica`.
public enum TeeAdmissionMode: String, Codable, Sendable {
    case replica
    case relay
}

/// The signed-release arm of a TEE admission policy: admit nodes running a
/// signed release with one of these profiles, instead of pinning measurements.
public struct SignedReleaseTeePolicy: Codable, Sendable, Equatable {
    public var allowedProfiles: [String]
    public var minReleaseVersion: String?
    public init(allowedProfiles: [String], minReleaseVersion: String? = nil) {
        self.allowedProfiles = allowedProfiles; self.minReleaseVersion = minReleaseVersion
    }
}

/// Body for `PUT /groups/{id}/settings/tee-admission-policy`.
///
/// Core rc.83 takes one of two forms, and validates them strictly (`400`):
/// - **Measurement**: `allowedMrtd` and `allowedRtmr1`/`2`/`3` must all be
///   non-empty, even with `acceptMock: true`. Use
///   ``measurement(allowedMrtd:allowedRtmr0:allowedRtmr1:allowedRtmr2:allowedRtmr3:allowedTcbStatuses:acceptMock:mode:rootProof:)``.
/// - **Signed release**: every measurement list empty, and
///   `signedRelease.allowedProfiles` non-empty. Use
///   ``signedRelease(_:allowedTcbStatuses:acceptMock:mode:rootProof:)``.
///
/// Changing the policy is a root-guarded owner op since rc.83: pass
/// `rootProof`, or call it on a node that holds the owner's account root.
public struct SetTeeAdmissionPolicyRequest: Codable, Sendable {
    public var allowedMrtd: [String]
    public var allowedRtmr0: [String]
    public var allowedRtmr1: [String]
    public var allowedRtmr2: [String]
    public var allowedRtmr3: [String]
    public var allowedTcbStatuses: [String]
    public var acceptMock: Bool
    /// The signed-release form. `nil` for the measurement form.
    public var signedRelease: SignedReleaseTeePolicy?
    /// `nil` lets the node apply its default, `replica`.
    public var mode: TeeAdmissionMode?
    /// Hex borsh `AccountProof<OwnerOpAuthorization>`. Omit it, never send `""`
    /// (an empty string is a `400`).
    public var rootProof: String?
    public init(
        allowedMrtd: [String], allowedRtmr0: [String], allowedRtmr1: [String], allowedRtmr2: [String],
        allowedRtmr3: [String], allowedTcbStatuses: [String], acceptMock: Bool,
        signedRelease: SignedReleaseTeePolicy? = nil, mode: TeeAdmissionMode? = nil, rootProof: String? = nil
    ) {
        self.allowedMrtd = allowedMrtd; self.allowedRtmr0 = allowedRtmr0; self.allowedRtmr1 = allowedRtmr1
        self.allowedRtmr2 = allowedRtmr2; self.allowedRtmr3 = allowedRtmr3
        self.allowedTcbStatuses = allowedTcbStatuses; self.acceptMock = acceptMock
        self.signedRelease = signedRelease; self.mode = mode; self.rootProof = rootProof
    }

    /// The measurement form. RTMR1, RTMR2 and RTMR3 are required, like MRTD.
    public static func measurement(
        allowedMrtd: [String], allowedRtmr0: [String] = [], allowedRtmr1: [String], allowedRtmr2: [String],
        allowedRtmr3: [String], allowedTcbStatuses: [String], acceptMock: Bool = false,
        mode: TeeAdmissionMode? = nil, rootProof: String? = nil
    ) -> SetTeeAdmissionPolicyRequest {
        SetTeeAdmissionPolicyRequest(
            allowedMrtd: allowedMrtd, allowedRtmr0: allowedRtmr0, allowedRtmr1: allowedRtmr1,
            allowedRtmr2: allowedRtmr2, allowedRtmr3: allowedRtmr3, allowedTcbStatuses: allowedTcbStatuses,
            acceptMock: acceptMock, mode: mode, rootProof: rootProof)
    }

    /// The signed-release form. Every measurement list is sent empty.
    public static func signedRelease(
        _ policy: SignedReleaseTeePolicy, allowedTcbStatuses: [String], acceptMock: Bool = false,
        mode: TeeAdmissionMode? = nil, rootProof: String? = nil
    ) -> SetTeeAdmissionPolicyRequest {
        SetTeeAdmissionPolicyRequest(
            allowedMrtd: [], allowedRtmr0: [], allowedRtmr1: [], allowedRtmr2: [], allowedRtmr3: [],
            allowedTcbStatuses: allowedTcbStatuses, acceptMock: acceptMock,
            signedRelease: policy, mode: mode, rootProof: rootProof)
    }
}

public struct GetTeeAdmissionPolicyResponseData: Codable, Sendable {
    /// `false` when no policy is set. `nil` on a node that predates the field.
    public let enabled: Bool?
    public let allowedMrtd: [String]
    public let allowedRtmr0: [String]
    public let allowedRtmr1: [String]
    public let allowedRtmr2: [String]
    public let allowedRtmr3: [String]
    public let allowedTcbStatuses: [String]
    public let acceptMock: Bool
    /// Set when the policy is the signed-release form.
    public let signedRelease: SignedReleaseTeePolicy?
    public let mode: TeeAdmissionMode?
    public init(
        allowedMrtd: [String], allowedRtmr0: [String], allowedRtmr1: [String], allowedRtmr2: [String],
        allowedRtmr3: [String], allowedTcbStatuses: [String], acceptMock: Bool,
        enabled: Bool? = nil, signedRelease: SignedReleaseTeePolicy? = nil, mode: TeeAdmissionMode? = nil
    ) {
        self.allowedMrtd = allowedMrtd; self.allowedRtmr0 = allowedRtmr0; self.allowedRtmr1 = allowedRtmr1
        self.allowedRtmr2 = allowedRtmr2; self.allowedRtmr3 = allowedRtmr3
        self.allowedTcbStatuses = allowedTcbStatuses; self.acceptMock = acceptMock
        self.enabled = enabled; self.signedRelease = signedRelease; self.mode = mode
    }
}
