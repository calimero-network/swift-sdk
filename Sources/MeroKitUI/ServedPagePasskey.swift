import Foundation
import MeroKit

/// The account's passkey for approvals (`412 CONFIRM_REQUIRED`: an invite, a
/// member's removal, …), asked on the app's served page.
/// (== apps `@calimero-apps/passkey/native`, `#native-approve`.)
///
/// A session from ``MeroClient/signInWithServedPage(cluster:callback:appsDomain:opener:)``
/// is bound to the package, and the node accepts its approvals only from the
/// package's own origin. A native app can't produce that with a
/// `calimero.network` passkey (iOS refuses it, and would report another
/// origin), so ``get(challenge:rpId:allowCredentials:)`` opens the served page
/// in the system sheet, the person approves there with their passkey, and the
/// assertion comes back sealed to a key made for this one approval.
public struct ServedPagePasskey: PasskeyProvider {
    public let origin: URL
    public let callback: CloudCallback
    public let opener: any WebAuthenticating
    public let session: URLSession

    @MainActor
    public init(
        origin: URL, callback: CloudCallback, opener: any WebAuthenticating = MeroClient.servedPageOpener(),
        session: URLSession = .shared
    ) {
        self.origin = origin
        self.callback = callback
        self.opener = opener
        self.session = session
    }

    /// Approvals only: a new passkey is made on the served page's sign-up.
    public func create(options: JSONValue) async throws -> RegistrationJSON {
        throw ServedPageSignInError("a new passkey is made on the sign-in page")
    }

    public func get(challenge: Data, rpId: String, allowCredentials: [String]?) async throws -> AssertionJSON {
        let version = try await AppHost.latestVersion(origin: origin, session: session)
        let handoff = ServedPageHandoff()
        var extra = [("challenge", b64url(challenge)), ("rpId", rpId)]
        if let allow = allowCredentials, !allow.isEmpty { extra.append(("allow", allow.joined(separator: ","))) }
        let url = handoff.url(origin: origin, version: version, fragment: ServedPageHandoff.approveFragment, extra: extra)
        let answer: URL
        do {
            answer = try await opener.authenticate(url: url, callback: callback)
        } catch is WebAuthenticationCancelled {
            throw PasskeyCancelled()
        }
        return try handoff.openApproval(answer)
    }
}

extension MeroClient {
    /// The passkey approvals go through: on Calimero Cloud the app's served
    /// page (``ServedPagePasskey``), on a development node ``passkeyForNode()``.
    public func approvalPasskey(
        cluster: String? = nil, callback: CloudCallback, appsDomain: String = AppHost.defaultDomain,
        opener: any WebAuthenticating = MeroClient.servedPageOpener()
    ) -> (any PasskeyProvider)? {
        guard !allowMock, let package = config.packageName else { return passkeyForNode() }
        return ServedPagePasskey(
            origin: AppHost.origin(package: package, cluster: cluster, domain: appsDomain), callback: callback,
            opener: opener, session: urlSession)
    }

    /// Where the node's consent page sends a package-bound session back: the
    /// package's served page (`{origin}/{version}/?native-consent=1`), which
    /// passes the answer on to the app's own scheme. The node takes only the
    /// package's own https origin as `returnTo`, never an app scheme.
    /// `nil` on a development node, where the app's callback is used as it is.
    public func servedConsentReturnTo(cluster: String? = nil, appsDomain: String = AppHost.defaultDomain) async throws
        -> String?
    {
        guard !allowMock, let package = config.packageName else { return nil }
        let origin = AppHost.origin(package: package, cluster: cluster, domain: appsDomain)
        let version = try await AppHost.latestVersion(origin: origin, session: urlSession)
        return ServedPageHandoff.consentReturnTo(origin: origin, version: version)
    }
}
