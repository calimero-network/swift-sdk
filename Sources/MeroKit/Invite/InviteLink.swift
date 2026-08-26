import Foundation

/// Shareable invitation links, matching `@calimero-network/mero-platform`.
///
/// A native app is a client of a node that runs on a computer, so the *link* is
/// not something the phone opens — it is something the phone hands to a person,
/// who opens it on the machine with the desktop app. There the launcher resolves
/// the slug, installs the app if it is missing, and joins the namespace. What
/// the phone needs is therefore only two things: build the link, and accept one
/// that somebody pastes back in.
///
/// That is why there is no URL-scheme registration or associated-domain setup
/// here. Nothing about this requires the OS to route a link to the app.
public enum InviteLink {

    /// Where shareable links point. Always HTTPS: an HTTPS link opens the web
    /// build directly and hands off to the desktop launcher on a machine that
    /// has it, whereas `calimero://` is a device-local transport that does not
    /// survive being pasted into a chat window.
    public static let defaultHost = "https://links.calimero.network"

    /// The intent verb an invitation carries.
    public static let joinAction = "join"

    /// The query parameter the payload travels in.
    public static let invitationParam = "invitation"

    /// Build a canonical shareable link.
    ///
    /// - Parameters:
    ///   - slug: the app's package id (e.g. `com.calimero.mero-ar`). The desktop
    ///     launcher matches this against `Application.package`, so it must equal
    ///     the id the app is published under — not a display name.
    ///   - action: the intent verb, normally ``joinAction``.
    ///   - params: query parameters; values are percent-encoded.
    public static func create(
        slug: String,
        action: String = joinAction,
        params: [String: String] = [:],
        host: String = defaultHost
    ) -> String {
        let base = host.hasSuffix("/") ? String(host.dropLast()) : host
        var components = URLComponents(string: "\(base)/\(escape(slug))/\(escape(action))")
        if !params.isEmpty {
            // Sorted so a given invitation always produces the same string.
            components?.queryItems = params.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components?.string ?? "\(base)/\(escape(slug))/\(escape(action))"
    }

    /// The shareable link for an invitation token.
    public static func invitation(token: String, slug: String, host: String = defaultHost) -> String {
        create(slug: slug, params: [invitationParam: token], host: host)
    }

    /// Pull the invitation token out of whatever a person pasted: a shareable
    /// HTTPS link, a `calimero://` link, or the bare token.
    ///
    /// `calimero://<slug>/<action>` is split by hand rather than with
    /// `URLComponents`, because host parsing on a non-special scheme mangles a
    /// dotted slug like `com.calimero.mero-ar`.
    ///
    /// Returns nil only for empty input — an unrecognized string is handed back
    /// unchanged, so a bare token still works and the codec gets the final say
    /// on whether it is valid.
    public static func token(fromPasted input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        guard
            lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || lower.hasPrefix("calimero://")
        else {
            return trimmed
        }

        // Take the query off by hand so the custom scheme is handled the same
        // way as HTTPS.
        guard let queryStart = trimmed.firstIndex(of: "?") else { return trimmed }
        let query = String(trimmed[trimmed.index(after: queryStart)...])
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == invitationParam else { continue }
            let value = String(parts[1])
            return value.removingPercentEncoding ?? value
        }
        return trimmed
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
