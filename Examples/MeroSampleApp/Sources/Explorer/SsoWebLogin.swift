import AuthenticationServices
import Foundation
import UIKit

/// Drives the hosted-SSO login: opens the node's `/auth/login` page in an
/// `ASWebAuthenticationSession` (the iOS analog of the web redirect that
/// mero-chat/mero-react use) and returns the callback URL, whose fragment
/// carries the tokens. No custom URL scheme needs registering in Info.plist —
/// `ASWebAuthenticationSession` intercepts the callback scheme itself.
final class SsoWebLogin: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window =
            scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
        return window ?? ASPresentationAnchor()
    }

    @MainActor
    func authenticate(loginURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: loginURL, callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    cont.resume(
                        throwing: NSError(
                            domain: "SSO", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "no callback URL returned"]))
                    return
                }
                cont.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                cont.resume(
                    throwing: NSError(
                        domain: "SSO", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "could not start the web auth session"]))
            }
        }
    }
}
