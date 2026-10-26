import Foundation
import MeroKit

#if canImport(Combine)
import Combine
#endif

// Capturing an invitation, however it arrived. Port of mero-react
// `invitations/capture.ts` and the `@calimero-network/mero-platform`
// deep-link controller under it.
//
// On iOS and macOS every link reaches the app through the system: a cold open
// and a warm one alike arrive at `onOpenURL` (a custom scheme, or a Universal
// Link for `https://links.calimero.network/<slug>/join?invitation=…`), and a
// pasted link through ``InvitationCapture/capture(raw:)``. Each is persisted
// (`UserDefaults`), deduplicated by a content nonce, replayed to a handler
// that registers late, and dropped only when the app acks it — so the landing
// screen does not matter, and arriving before the session is ready is fine.

/// The action an invite link carries: `…/<package>/join?invitation=…`.
public let invitationJoinAction = "join"
/// The query parameter every app's invite link carries the token in.
public let invitationParam = "invitation"
/// How many launches may auto-join one invitation before it needs a person.
/// (== mero-react `MAX_AUTO_JOIN_ATTEMPTS`.)
public let maxAutoJoinAttempts = 3

/// One captured invitation, with the ack the app owes the store.
/// (== mero-react `CapturedInvitation`.)
public struct CapturedInvitation: Identifiable {
    /// The raw invitation token, ready to parse.
    public let token: String
    /// Every query parameter the link carried, the token included.
    public let params: [String: String]
    /// Whether to attempt the join without being asked. `false` once this
    /// invitation has spent its automatic attempts: it is still handed over,
    /// so a retry is one tap, but it stops re-firing on every launch.
    public let autoJoin: Bool
    let ack: @MainActor () -> Void

    public var id: String { token }

    /// Ack it so the store stops replaying it. Call once handled **or** declined.
    @MainActor
    public func resolve() {
        ack()
    }
}

/// A raw link split into slug, action and query. (== mero-platform `parseIntent`.)
public struct InvitationIntent: Sendable, Equatable {
    public let slug: String?
    public let action: String?
    public let params: [String: String]

    /// `calimero://<slug>/<action>?…` is split by hand: host parsing on a
    /// custom scheme mangles a dotted slug like `com.calimero.curb`. Anything
    /// else is read as a URL against a placeholder base, so a bare path works.
    public static func parse(_ raw: String) -> InvitationIntent {
        if raw.lowercased().hasPrefix("calimero://") {
            let rest = String(raw.dropFirst("calimero://".count))
            let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            let segments = parts[0].split(separator: "/").map(String.init)
            let query = parts.count > 1 ? String(parts[1]) : ""
            return InvitationIntent(
                slug: segments.first, action: segments.count > 1 ? segments[1] : nil,
                params: invitationFormQuery(query))
        }
        let base = URL(string: "https://x.invalid/")
        guard let url = URL(string: raw, relativeTo: base) ?? URL(string: raw) else {
            return InvitationIntent(slug: nil, action: nil, params: [:])
        }
        let segments = url.path.split(separator: "/").map(String.init)
        return InvitationIntent(
            slug: segments.first, action: segments.count > 1 ? segments[1] : nil,
            params: invitationFormQuery(url.query ?? ""))
    }

    /// Whether a link carries anything worth capturing: a query, or a path.
    static func hasSignal(_ raw: String) -> Bool {
        guard let url = URL(string: raw, relativeTo: URL(string: "https://x.invalid/")) else { return false }
        return !(url.query ?? "").isEmpty || !url.path.split(separator: "/").isEmpty
    }
}

/// `application/x-www-form-urlencoded` pairs, as `URLSearchParams` reads them
/// (`+` is a space); a later duplicate wins, as an object assignment does.
func invitationFormQuery(_ query: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        func decode(_ text: Substring) -> String {
            let spaced = text.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        let key = decode(parts[0])
        guard !key.isEmpty else { continue }
        out[key] = parts.count > 1 ? decode(parts[1]) : ""
    }
    return out
}

/// `URLSearchParams`' encoding of one value.
func invitationFormEncode(_ value: String) -> String {
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._ ")
    let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    return encoded.replacingOccurrences(of: " ", with: "+")
}

/// The token in a raw deep-link payload — a link carrying `invitation=…`, or a
/// bare code — or `nil` if it carries none. A page URL or path without the
/// parameter is not a code. (== mero-react `invitationFromRaw`.)
public func invitationFromRaw(_ raw: String) -> String? {
    let direct = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !direct.isEmpty else { return nil }
    let query = direct.firstIndex(of: "?").map { String(direct[direct.index(after: $0)...]) } ?? direct
    if let found = invitationFormQuery(query)[invitationParam]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !found.isEmpty
    {
        return found
    }
    if direct.contains("=") || direct.contains("?") || direct.hasPrefix("/") { return nil }
    if direct.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil { return nil }
    return direct
}

/// `href` with the invitation parameter removed. (== mero-react `urlWithoutInvitation`.)
public func urlWithoutInvitation(_ href: String) -> String {
    guard var components = URLComponents(string: href), let items = components.queryItems,
        items.contains(where: { $0.name == invitationParam })
    else { return href }
    let kept = items.filter { $0.name != invitationParam }
    components.queryItems = kept.isEmpty ? nil : kept
    return components.string ?? href
}

/// The link an inviter shares, for every app:
/// `https://links.calimero.network/<slug>/join?invitation=…`, with `extra`
/// parameters beside the token (an empty or `nil` one is left out).
/// `slug` is the app's package id. (== mero-react `buildInviteLink`.)
///
/// HTTPS by default — it opens the web build, hands off to the desktop, and
/// (with Associated Domains) opens this app. Pass `host: "calimero:/"` for the
/// device-local `calimero://<slug>/join?…` form.
public func buildInviteLink(
    slug: String, token: String, extra: KeyValuePairs<String, String?> = [:], host: String = InviteLink.defaultHost
) -> String {
    var base = host
    while base.hasSuffix("/") { base.removeLast() }
    // A bare scheme (`calimero:/`, `calimero://`) keeps its `//`.
    if base.hasSuffix(":") { base += "/" }
    let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    let segment = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? text }
    var pairs: [(String, String)] = [(invitationParam, token)]
    for (key, value) in extra {
        guard let value, !value.isEmpty else { continue }
        pairs.removeAll { $0.0 == key }
        pairs.append((key, value))
    }
    let query = pairs.map { "\(invitationFormEncode($0.0))=\(invitationFormEncode($0.1))" }.joined(separator: "&")
    return "\(base)/\(segment(slug))/\(segment(invitationJoinAction))?\(query)"
}

/// Durable pending intents: deduplicated by content nonce, dropped only on
/// ack. (== mero-platform `PendingIntentStore`; the key is the same.)
final class PendingIntentStore: @unchecked Sendable {
    struct Intent: Codable, Equatable, Sendable {
        let nonce: String
        let raw: String
        let capturedAt: Double
    }

    static let storageKey = "calimero.platform.pendingIntents"
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// FNV-1a 32-bit over UTF-16 code units, as mero-platform computes it.
    static func nonce(_ raw: String) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for unit in raw.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    func all() -> [Intent] {
        guard let data = defaults.data(forKey: Self.storageKey),
            let list = try? JSONDecoder().decode([Intent].self, from: data)
        else { return [] }
        return list
    }

    private func write(_ list: [Intent]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.storageKey) }
    }

    /// Capture `raw`; idempotent by nonce. Returns the stored entry.
    @discardableResult
    func capture(_ raw: String) -> Intent {
        let nonce = Self.nonce(raw)
        var list = all()
        if let existing = list.first(where: { $0.nonce == nonce }) { return existing }
        let intent = Intent(nonce: nonce, raw: raw, capturedAt: now().timeIntervalSince1970 * 1000)
        list.append(intent)
        write(list)
        return intent
    }

    func ack(_ nonce: String) {
        write(all().filter { $0.nonce != nonce })
    }
}

/// Funnels every inbound invitation link into one place.
/// (== mero-react `primeInvitationCapture` / `onInvitation` /
/// `peekInvitation` / `subscribeInvitation`, as one object.)
///
/// Prime it once at launch (``prime(appKey:slugs:)``) and feed it every URL
/// the app opens (``handle(_:)``, from `onOpenURL` and
/// `onContinueUserActivity`). A ``InviteRedemption`` subscribes with
/// ``onInvitation(_:)``; a logged-out screen reads ``current`` without
/// taking it.
@MainActor
public final class InvitationCapture: ObservableObject {
    /// The app's capture, backed by `UserDefaults.standard`.
    public static let shared = InvitationCapture()

    /// The captured invitation, held until acked — for code that only needs to
    /// know one is inbound. (== mero-react `peekInvitation`.)
    @Published public private(set) var current: CapturedInvitation?

    private let store: PendingIntentStore
    private let defaults: UserDefaults
    private var started = false
    private var delivered: Set<String> = []
    private var listeners: [UUID: (CapturedInvitation) -> Void] = [:]
    private var watchers: [UUID: () -> Void] = [:]
    private var buffered: CapturedInvitation?
    private var attemptsKey = "calimero:invitation-attempts"
    private var ownSlugs: Set<String> = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.store = PendingIntentStore(defaults: defaults)
    }

    /// Start capturing, replaying any invitation a previous launch left
    /// unacked. `appKey` namespaces the attempt ledger; `slugs` are this app's
    /// package ids — a `join` link for any other app is dropped (acked, never
    /// offered). (== mero-react `primeInvitationCapture`.)
    public func prime(appKey: String? = nil, slugs: [String] = []) {
        if let appKey, !appKey.isEmpty { attemptsKey = "\(appKey):invitation-attempts" }
        if !slugs.isEmpty { ownSlugs = Set(slugs) }
        ensureStarted()
    }

    /// Capture a URL the app was opened with. Returns whether it named an
    /// invitation this app takes.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        capture(raw: url.absoluteString)
    }

    /// Capture a raw link or code (a paste, a bridge payload). Returns whether
    /// an invitation for this app was delivered.
    @discardableResult
    public func capture(raw: String) -> Bool {
        ensureStarted()
        let isLink = raw.contains("://") || raw.hasPrefix("/")
        guard !isLink || InvitationIntent.hasSignal(raw) else { return false }
        let intent = store.capture(raw)
        guard !delivered.contains(intent.nonce) else { return false }
        delivered.insert(intent.nonce)
        return process(intent)
    }

    /// Be handed invitations. One already captured is replayed now, so a
    /// handler set up after the link opened still sees it. Returns the
    /// cancel. (== mero-react `onInvitation`.)
    @discardableResult
    public func onInvitation(_ listener: @escaping (CapturedInvitation) -> Void) -> () -> Void {
        ensureStarted()
        let id = UUID()
        listeners[id] = listener
        if let pending = buffered {
            buffered = nil
            listener(pending)
        }
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// The captured invitation right now, without taking it. (== mero-react `peekInvitation`.)
    public func peek() -> CapturedInvitation? {
        ensureStarted()
        return current
    }

    /// Be told whenever ``current`` changes. (== mero-react `subscribeInvitation`.)
    @discardableResult
    public func subscribe(_ watcher: @escaping () -> Void) -> () -> Void {
        ensureStarted()
        let id = UUID()
        watchers[id] = watcher
        return { [weak self] in self?.watchers[id] = nil }
    }

    /// Forget listeners, the buffer and what this run delivered (the store
    /// and the ledger stay) — what a relaunch does. For tests.
    public func reset() {
        started = false
        delivered = []
        listeners = [:]
        buffered = nil
        attemptsKey = "calimero:invitation-attempts"
        ownSlugs = []
        setCurrent(nil)
    }

    // MARK: - Internals

    private func ensureStarted() {
        guard !started else { return }
        started = true
        for intent in store.all() where !delivered.contains(intent.nonce) {
            delivered.insert(intent.nonce)
            process(intent)
        }
    }

    @discardableResult
    private func process(_ stored: PendingIntentStore.Intent) -> Bool {
        let intent = InvitationIntent.parse(stored.raw)
        // `join`, or no action at all (the app's own URL carrying
        // `?invitation=`); a deeper page with the parameter is still ours.
        if let action = intent.action, action != invitationJoinAction, intent.params[invitationParam] == nil {
            return false
        }
        // A join addressed to another app: acked so it does not replay, never offered.
        let foreign = intent.slug.map { !ownSlugs.isEmpty && !ownSlugs.contains($0) } ?? false
        if intent.action == invitationJoinAction, foreign {
            store.ack(stored.nonce)
            return false
        }
        guard let token = invitationFromRaw(stored.raw) else {
            // Nothing for us in it, but still ours to ack or it replays forever.
            store.ack(stored.nonce)
            return false
        }
        var params = intent.params
        params[invitationParam] = token
        let nonce = stored.nonce
        // The ack is durable work on the store and the ledger, so it holds
        // them itself: an invitation outlives the capture that delivered it
        // (a relaunch makes a new one over the same defaults).
        let store = self.store
        let defaults = self.defaults
        let ledgerKey = attemptsKey
        let captured = CapturedInvitation(
            token: token, params: params, autoJoin: spendAttempt(token),
            ack: { [weak self] in
                Self.forgetAttempts(token, defaults: defaults, key: ledgerKey)
                store.ack(nonce)
                self?.acked(token: token)
            })
        deliver(captured)
        return true
    }

    /// The in-memory side of an ack (the store and the ledger are done by the ack itself).
    private func acked(token: String) {
        // Acked before any listener took it (declined while logged out): it
        // must not be replayed to the redemption that subscribes after login.
        if buffered?.token == token { buffered = nil }
        if current?.token == token { setCurrent(nil) }
    }

    private func deliver(_ invitation: CapturedInvitation) {
        setCurrent(invitation)
        guard !listeners.isEmpty else {
            buffered = invitation
            return
        }
        for listener in Array(listeners.values) { listener(invitation) }
    }

    private func setCurrent(_ invitation: CapturedInvitation?) {
        current = invitation
        for watcher in Array(watchers.values) { watcher() }
    }

    // MARK: - Attempt ledger

    private nonisolated static func readAttempts(defaults: UserDefaults, key: String) -> [String: Int] {
        guard let data = defaults.data(forKey: key),
            let parsed = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return parsed
    }

    private nonisolated static func writeAttempts(_ attempts: [String: Int], defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(attempts) { defaults.set(data, forKey: key) }
    }

    private func readAttempts() -> [String: Int] {
        Self.readAttempts(defaults: defaults, key: attemptsKey)
    }

    private func writeAttempts(_ attempts: [String: Int]) {
        Self.writeAttempts(attempts, defaults: defaults, key: attemptsKey)
    }

    /// Count this launch's attempt; whether it is still within the cap.
    private func spendAttempt(_ token: String) -> Bool {
        var attempts = readAttempts()
        let spent = attempts[token] ?? 0
        if spent >= maxAutoJoinAttempts { return false }
        attempts[token] = spent + 1
        writeAttempts(attempts)
        return true
    }

    private nonisolated static func forgetAttempts(_ token: String, defaults: UserDefaults, key: String) {
        var attempts = readAttempts(defaults: defaults, key: key)
        guard attempts.removeValue(forKey: token) != nil else { return }
        writeAttempts(attempts, defaults: defaults, key: key)
    }

    /// The attempts recorded for `token`. For tests and diagnostics.
    public func attempts(for token: String) -> Int {
        readAttempts()[token] ?? 0
    }

    /// Forget the auto-join attempt ledger, which names the invitations this
    /// device tried. ``MeroClient/logout(forgetDevice:)`` does, so the next
    /// account starts with none; a pending invitation stays until acked.
    public func clearAttempts() {
        defaults.removeObject(forKey: attemptsKey)
    }
}

/// Start capturing on ``InvitationCapture/shared``. (== mero-react `primeInvitationCapture`.)
@MainActor
public func primeInvitationCapture(appKey: String? = nil, slug: [String] = []) {
    InvitationCapture.shared.prime(appKey: appKey, slugs: slug)
}

/// Subscribe on ``InvitationCapture/shared``. (== mero-react `onInvitation`.)
@MainActor
@discardableResult
public func onInvitation(_ listener: @escaping (CapturedInvitation) -> Void) -> () -> Void {
    InvitationCapture.shared.onInvitation(listener)
}

/// ``InvitationCapture/shared``'s current invitation. (== mero-react `peekInvitation`.)
@MainActor
public func peekInvitation() -> CapturedInvitation? {
    InvitationCapture.shared.peek()
}

/// Watch ``InvitationCapture/shared``. (== mero-react `subscribeInvitation`.)
@MainActor
@discardableResult
public func subscribeInvitation(_ watcher: @escaping () -> Void) -> () -> Void {
    InvitationCapture.shared.subscribe(watcher)
}
