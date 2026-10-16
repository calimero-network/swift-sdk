import Foundation
import MeroKit

// The Calimero Cloud pages a person completes by hand, opened in the system
// auth sheet. mero-js opens them with `window.open` / `window.location`; here
// a ``WebAuthenticating`` presents the page and hands back the URL it
// redirected to, so the flows can be driven without a browser in tests.

extension CloudClient {
    /// Open the cloud's `/enable-ha` page for a person to complete, and wait
    /// until it sends them back. `options.redirectUrl` defaults to
    /// `callback.url`. Returns the URL the page redirected to.
    /// (== mero-js `CloudClient.enableHA`.) For the API call, see
    /// ``CloudClient/enableNamespaceHa(_:admitterAddrs:)``.
    @discardableResult
    public func enableHA(
        _ options: HAPageOptions, callback: CloudCallback, authenticator: any WebAuthenticating
    ) async throws -> URL {
        let url = try enableHAURL(Self.redirecting(options, to: callback))
        return try await authenticator.authenticate(url: url, callback: callback)
    }

    /// Open the cloud's `/disable-ha` page. See ``enableHA(_:callback:authenticator:)``.
    @discardableResult
    public func disableHA(
        _ options: HAPageOptions, callback: CloudCallback, authenticator: any WebAuthenticating
    ) async throws -> URL {
        let url = try disableHAURL(Self.redirecting(options, to: callback))
        return try await authenticator.authenticate(url: url, callback: callback)
    }

    private static func redirecting(_ options: HAPageOptions, to callback: CloudCallback) -> HAPageOptions {
        var options = options
        if options.redirectUrl == nil { options.redirectUrl = callback.url }
        return options
    }
}

extension CloudLink {
    /// Send the person to the cloud to consent to linking `accountId`, and
    /// read the grant it sends back: ``CloudLink/cloudLinkUrl(accountId:returnTo:cloudWebURL:stateStore:)``
    /// presented by `authenticator`, then
    /// ``CloudLink/readCloudLinkCallback(_:stateStore:)`` on the answer.
    /// (== mero-js `beginCloudLink`, which redirects the page instead.)
    ///
    /// Spend the result with ``CloudLink/completeCloudLink(_:root:cloudBaseURL:session:)``.
    /// Throws ``AccountError/linkDeclined(_:)`` when the person declined, and
    /// ``WebAuthenticationCancelled`` when they closed the sheet.
    public static func beginCloudLink(
        accountId: String, callback: CloudCallback, cloudWebURL: URL = CloudLink.defaultCloudWebURL,
        stateStore: CloudLinkStateStore = .shared, authenticator: any WebAuthenticating
    ) async throws -> CloudLinkCallback {
        let url = try cloudLinkUrl(
            accountId: accountId, returnTo: callback.url, cloudWebURL: cloudWebURL, stateStore: stateStore)
        let answer = try await authenticator.authenticate(url: url, callback: callback)
        guard let grant = try readCloudLinkCallback(answer, stateStore: stateStore) else {
            throw AccountError.protocolViolation("the cloud returned no link grant")
        }
        return grant
    }
}
