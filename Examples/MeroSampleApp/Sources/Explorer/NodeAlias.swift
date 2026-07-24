import Foundation

/// **Cosmetic, demo-only** mapping between the localhost nodes we actually run and
/// public-looking IPs shown in the UI — so screenshots/marketing read like the app
/// is talking to remote nodes while it really connects to `localhost` (we can't
/// host public nodes yet). Only these known localhost URLs are aliased; any other
/// URL (a genuinely remote node) passes through unchanged, so this is invisible in
/// real deployments and to the e2e tests (which drive localhost).
///
/// - `display(_:)` — real URL → the label to show in the UI.
/// - `real(_:)`    — a shown label (or real URL) → the URL to actually connect to.
enum NodeAlias {
    /// (public-looking label shown in the UI, real URL the client connects to).
    private static let pairs: [(shown: String, real: String)] = [
        ("http://73.34.123.11:4001", "http://localhost:4001"),  // node A / dev1
        ("http://123.47.42.90:4011", "http://localhost:4011"),  // node B / dev2
    ]

    /// The public-looking label to show for a real node URL.
    static func display(_ url: String) -> String {
        let key = normalize(url)
        return pairs.first { normalize($0.real) == key }?.shown ?? url
    }

    /// The real URL to connect to for a (possibly aliased) label.
    static func real(_ url: String) -> String {
        let key = normalize(url)
        return pairs.first { normalize($0.shown) == key }?.real ?? url
    }

    private static func normalize(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "127.0.0.1", with: "localhost")
    }
}
