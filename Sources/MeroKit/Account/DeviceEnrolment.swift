import Foundation

/// What came back from the wallet in the callback fragment, **unverified**.
public struct EnrolmentCallback: Sendable, Equatable {
    /// The `AccountProof<DeviceCert>`, hex borsh.
    public let credential: String
    /// The account the wallet says certified this device, 64 hex.
    public let account: String
    /// The device id the wallet minted, 64 hex.
    public let device: String
    /// The `state` the app sent, echoed back.
    public let state: String?

    public init(credential: String, account: String, device: String, state: String?) {
        self.credential = credential
        self.account = account
        self.device = device
        self.state = state
    }
}

/// A device this app may now sign as — everything in it already checked.
public struct EnrolledDevice: Sendable, Equatable {
    /// The credential to present (`authorProof`), hex.
    public let credential: String
    public let account: String
    public let device: String
    public let certificate: DeviceCredential
}

/// Getting this app's device key certified by the Calimero wallet.
///
/// Port of mero-js `src/cloud/enrol-redirect.ts`. The app opens the wallet's
/// `account-enroll` page naming its keys; the person approves with their
/// passkey there; the wallet redirects to the callback with
/// `#credential=…&account=…&device=…&state=…` (or `#error=…`).
///
/// Unlike mero-js, the callback may be **any** URL — an https Universal Link
/// or an app scheme such as `mero-sample://enrol`. A native app has no page
/// origin to protect, and the credential certifies a key that never leaves the
/// app; see ``completeEnrolment(_:keys:expectState:)`` for what is checked.
public enum DeviceEnrolment {
    /// The hosted wallet's enrolment page.
    public static let defaultWalletURL = URL(string: "https://wallet.cloud.calimero.network/account-enroll")!

    /// The URL to open in the system auth sheet.
    ///
    /// - Parameters:
    ///   - walletURL: the wallet page (``defaultWalletURL``).
    ///   - devicePublicKey: the Ed25519 key to certify, 64 lowercase hex.
    ///   - kemPublicKey: the X25519 delivery key, 64 lowercase hex.
    ///   - callbackURL: where the wallet sends the answer. Must not carry a
    ///     fragment (the wallet appends one).
    ///   - state: an opaque value echoed back, compared on return.
    public static func url(
        walletURL: URL = defaultWalletURL, devicePublicKey: String, kemPublicKey: String,
        callbackURL: String, state: String?
    ) throws -> URL {
        try assertLowerHex32(devicePublicKey, "devicePublicKey")
        try assertLowerHex32(kemPublicKey, "kemPublicKey")
        guard let callback = URL(string: callbackURL), callback.scheme != nil else {
            throw AccountError.invalidInput("callbackURL must be an absolute URL, got \(callbackURL)")
        }
        guard callback.fragment == nil, !callbackURL.contains("#") else {
            throw AccountError.invalidInput("callbackURL must not carry a fragment; the wallet appends one")
        }
        if let scheme = callback.scheme?.lowercased(), refusedSchemes.contains(scheme) {
            throw AccountError.invalidInput("callbackURL may not use the \(scheme): scheme")
        }

        var params: [(String, String)] = [
            ("enrol-device", devicePublicKey),
            ("enrol-kem", kemPublicKey),
            ("callback-url", callbackURL),
        ]
        if let state, !state.isEmpty { params.append(("state", state)) }

        guard var components = URLComponents(url: walletURL, resolvingAgainstBaseURL: false) else {
            throw AccountError.invalidInput("walletURL is not a URL: \(walletURL)")
        }
        let existing = components.percentEncodedQuery.map { $0.isEmpty ? [] : [$0] } ?? []
        let encoded = params.map { "\(formEncode($0.0))=\(formEncode($0.1))" }
        components.percentEncodedQuery = (existing + encoded).joined(separator: "&")
        guard let url = components.url else {
            throw AccountError.invalidInput("could not build the enrolment URL")
        }
        return url
    }

    /// A fresh `state`: 16 random bytes, hex.
    public static func makeState() -> String { Hex.encode(randomBytes(16)) }

    /// Read an enrolment out of a callback URL's fragment.
    ///
    /// Returns `nil` when the URL carries no enrolment, so it can be run on
    /// every incoming URL. Throws when the person declined or the wallet
    /// refused. Nothing is verified — see ``completeEnrolment(_:keys:expectState:)``.
    public static func readCallback(_ url: URL) throws -> EnrolmentCallback? {
        try readCallback(fragment: url.fragment ?? "")
    }

    /// As ``readCallback(_:)``, from the raw fragment (without `#`).
    public static func readCallback(fragment: String) throws -> EnrolmentCallback? {
        let params = formDecodeQuery(fragment)
        if let error = params["error"], !error.isEmpty {
            throw AccountError.enrolmentDeclined(
                error == "denied" || error == "cancelled"
                    ? "The device was not approved at the wallet."
                    : "The wallet refused this enrolment: \(error)")
        }
        guard let credential = params["credential"], !credential.isEmpty,
            let account = params["account"], !account.isEmpty,
            let device = params["device"], !device.isEmpty
        else { return nil }
        let state = params["state"].flatMap { $0.isEmpty ? nil : $0 }
        return EnrolmentCallback(credential: credential, account: account, device: device, state: state)
    }

    /// Verify what came back, and refuse loudly rather than return a
    /// half-checked credential. Every throw is a credential that must not be
    /// stored.
    ///
    /// Checks, in order: the `state` (when the app has one to compare), the
    /// certificate itself (``DeviceCertificates/verify(_:)``), that it
    /// certifies **this** app's signing and delivery keys, and that the account
    /// and device reported beside it are the ones it names.
    public static func completeEnrolment(
        _ callback: EnrolmentCallback, devicePublicKey: String, kemPublicKey: String?, expectState: String?
    ) throws -> EnrolledDevice {
        if let expectState, expectState != callback.state {
            throw AccountError.stateMismatch
        }

        let certificate = try DeviceCertificates.verify(callback.credential)

        let mine = normalise(devicePublicKey)
        guard certificate.signPublicKey == mine else {
            throw AccountError.credentialRejected(
                "this credential certifies device key \(certificate.signPublicKey), but this app holds \(mine) — it "
                    + "would sign with a key the certificate does not cover")
        }
        if let kemPublicKey, certificate.kemPublicKey != normalise(kemPublicKey) {
            throw AccountError.credentialRejected(
                "this credential names delivery key \(certificate.kemPublicKey), not the one this app asked about — "
                    + "group keys would be sealed to somebody else")
        }
        guard certificate.account == normalise(callback.account) else {
            throw AccountError.credentialRejected(
                "the wallet reported account \(normalise(callback.account)), but the credential names "
                    + "\(certificate.account)")
        }
        guard certificate.device == normalise(callback.device) else {
            throw AccountError.credentialRejected(
                "the wallet reported device \(normalise(callback.device)), but the credential names "
                    + "\(certificate.device)")
        }
        return EnrolledDevice(
            credential: callback.credential.lowercased(), account: certificate.account,
            device: certificate.device, certificate: certificate)
    }

    /// ``completeEnrolment(_:devicePublicKey:kemPublicKey:expectState:)`` for `keys`.
    public static func completeEnrolment(
        _ callback: EnrolmentCallback, keys: DeviceKeys, expectState: String?
    ) throws -> EnrolledDevice {
        try completeEnrolment(
            callback, devicePublicKey: keys.signPublicKey, kemPublicKey: keys.kemPublicKey,
            expectState: expectState)
    }

    // MARK: - Helpers

    /// Schemes that would ask the wallet to run or read something rather than
    /// hand a credential to an app.
    static let refusedSchemes: Set<String> = [
        "javascript", "data", "blob", "file", "about", "vbscript", "filesystem", "intent",
    ]

    private static func assertLowerHex32(_ value: String, _ label: String) throws {
        guard value.count == 64, value == value.lowercased(), Hex.is32(value) else {
            throw AccountError.invalidInput("\(label) must be 64 lowercase hex characters")
        }
    }

    private static func normalise(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `application/x-www-form-urlencoded`, as `URLSearchParams` writes it.
    static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._ ")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: " ", with: "+")
    }

    /// Parse `a=b&c=d` the way `URLSearchParams` does (`+` is a space).
    static func formDecodeQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let plussed = s.replacingOccurrences(of: "+", with: " ")
                return plussed.removingPercentEncoding ?? plussed
            }
            let key = decode(kv[0])
            if out[key] == nil { out[key] = kv.count > 1 ? decode(kv[1]) : "" }
        }
        return out
    }
}
