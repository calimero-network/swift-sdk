import Foundation
import MeroKit

// Redeeming an invitation that arrived by link. Port of mero-react
// `invitations/useInviteRedemption.ts`, `describeInviteFailure.ts` and
// `justJoined.ts`.

/// What to tell a person about a failed join, or `nil` to show the node's own
/// message (an `unknown` failure has nothing better). `noun` is what the app
/// calls the thing joined: "team", "space", "vault".
/// (== mero-react `describeInviteFailure`.)
public func describeInviteFailure(_ reason: InviteFailureReason, noun: String = "team") -> String? {
    switch reason {
    case .expired:
        return "This invitation has expired. Ask for a new link."
    case .invalid:
        return "This invitation link isn't valid. Ask for a new one."
    case .refused:
        return "You can't join this \(noun) with this invitation. Ask an admin to invite you again."
    case .signedOut:
        return "Your session with your node has ended. Sign in again to finish joining."
    case .noOneOnline:
        return "No one in this \(noun) is online to let you in yet. "
            + "It will try again the next time you open the app."
    case .nodeUnreachable:
        return "Couldn't reach your node. Check that it is running, then try again."
    case .unknown:
        return nil
    }
}

// MARK: - Just joined

/// The namespaces this launch has just joined and is still waiting on.
/// (== mero-react `justJoined.ts`; `sessionStorage` there, this process here:
/// the flag covers the window between a join returning and its data
/// arriving, and must not outlive the launch.)
@MainActor
public final class JustJoinedNamespaces: ObservableObject {
    public static let shared = JustJoinedNamespaces()

    @Published public private(set) var namespaces: Set<String> = []
    private var listeners: [UUID: () -> Void] = [:]

    public init() {}

    /// Call the moment a join succeeds, before navigating.
    /// (== mero-react `markNamespaceJustJoined`.)
    public func mark(_ namespaceId: String) {
        guard !namespaceId.isEmpty, !namespaces.contains(namespaceId) else { return }
        namespaces.insert(namespaceId)
        notify()
    }

    /// (== mero-react `clearNamespaceJustJoined`.)
    public func clear(_ namespaceId: String) {
        guard namespaces.remove(namespaceId) != nil else { return }
        notify()
    }

    /// (== mero-react `isNamespaceJustJoined`.)
    public func contains(_ namespaceId: String?) -> Bool {
        guard let namespaceId, !namespaceId.isEmpty else { return false }
        return namespaces.contains(namespaceId)
    }

    /// Hear every mark and clear. Returns the cancel. (== mero-react `subscribeJustJoined`.)
    @discardableResult
    public func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// Forget every flag. For tests.
    public func removeAll() {
        namespaces = []
        notify()
    }

    private func notify() {
        for listener in Array(listeners.values) { listener() }
    }
}

/// (== mero-react `markNamespaceJustJoined`.)
@MainActor
public func markNamespaceJustJoined(_ namespaceId: String) {
    JustJoinedNamespaces.shared.mark(namespaceId)
}

/// (== mero-react `clearNamespaceJustJoined`.)
@MainActor
public func clearNamespaceJustJoined(_ namespaceId: String) {
    JustJoinedNamespaces.shared.clear(namespaceId)
}

/// (== mero-react `isNamespaceJustJoined`.)
@MainActor
public func isNamespaceJustJoined(_ namespaceId: String?) -> Bool {
    JustJoinedNamespaces.shared.contains(namespaceId)
}

// MARK: - Redemption

/// What a token carries, once the app's codec has read it.
/// (== mero-react `ParsedInvitation`.)
public struct ParsedInvitation: Sendable {
    public var namespaceId: String
    /// The invitation the node's join takes.
    public var invitation: SignedGroupOpenInvitation
    /// The human name the inviter embedded, if any.
    public var teamName: String?
    /// The context the invitation is for, when it names one.
    public var contextId: String?
    /// Anything else the app's codec read (a vault name, a target id).
    public var extra: [String: String]

    public init(
        namespaceId: String, invitation: SignedGroupOpenInvitation, teamName: String? = nil, contextId: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.namespaceId = namespaceId
        self.invitation = invitation
        self.teamName = teamName
        self.contextId = contextId
        self.extra = extra
    }
}

/// Where redemption has got to, for rendering. (== mero-react `InviteState`.)
public enum InviteState: Sendable, Equatable {
    case idle
    case awaitingConfirmation(teamName: String?)
    /// The state the apps used to lack: a join can take up to a minute and a
    /// half when no member is online.
    case joining(teamName: String?)
    case joined(namespaceId: String, teamName: String?)
    case alreadyMember(namespaceId: String, teamName: String?)
    /// `message` is the node's words (or this package's for an unreadable
    /// link); ``describeInviteFailure(_:noun:)`` turns `reason` into plain words.
    case failed(message: String, reason: InviteFailureReason, retryable: Bool)

    /// mero-react's `stage` string.
    public var stage: String {
        switch self {
        case .idle: return "idle"
        case .awaitingConfirmation: return "awaiting-confirmation"
        case .joining: return "joining"
        case .joined: return "joined"
        case .alreadyMember: return "already-member"
        case .failed: return "failed"
        }
    }

    public var teamName: String? {
        switch self {
        case .awaitingConfirmation(let name), .joining(let name): return name
        case .joined(_, let name), .alreadyMember(_, let name): return name
        case .idle, .failed: return nil
        }
    }
}

/// Redeem an invitation that arrived by link, and report progress.
/// (== mero-react `useInviteRedemption`.)
///
/// Keep one for the app's life (a `@StateObject` at the root). Capture is
/// process-wide and buffers, so starting late is safe. The invitation is
/// acked on the *outcome* — joined, already a member, or failed for good —
/// never on display; a retryable failure keeps it for the next launch, up to
/// ``maxAutoJoinAttempts`` automatic tries.
///
/// By default it asks first (``InviteState/awaitingConfirmation(teamName:)``):
/// joining puts this device in someone else's namespace, so a forwarded link
/// must not join silently.
@MainActor
public final class InviteRedemption: ObservableObject {
    public typealias Parse = (_ token: String, _ params: [String: String]) -> ParsedInvitation?
    public typealias Redeem = (ParsedInvitation) async -> RedeemOutcome

    @Published public private(set) var state: InviteState = .idle
    /// The captured token, for prefilling a manual join field.
    @Published public private(set) var token: String?
    /// What the invitation names, available while confirming.
    @Published public private(set) var parsed: ParsedInvitation?

    private let parse: Parse
    private let redeem: Redeem?
    private let redeemer: InviteRedeemer?
    /// Ask before joining. Off only for a caller that has already asked.
    public var confirm: Bool
    /// Called once a join has landed (``InviteState/alreadyMember(namespaceId:teamName:)`` too).
    public var onJoined: ((String, String?) -> Void)?
    private let capture: InvitationCapture
    private let justJoined: JustJoinedNamespaces
    private var attempted: Set<String> = []
    private var pending: CapturedInvitation?
    private var cancel: (() -> Void)?

    /// - Parameters:
    ///   - parse: the app's codec; `nil` (or a missing namespace) for an unusable token.
    ///   - redeem: the app's own join flow; takes precedence over `redeemer`.
    ///     Report failure as a `.failed` outcome.
    ///   - redeemer: the standard join (join, then check membership).
    ///   - enabled: start listening now; otherwise call ``enable()`` once the
    ///     app can join (a session, a resolved application).
    public init(
        parse: @escaping Parse, redeem: Redeem? = nil, redeemer: InviteRedeemer? = nil, confirm: Bool = true,
        onJoined: ((String, String?) -> Void)? = nil, enabled: Bool = true,
        capture: InvitationCapture = .shared, justJoined: JustJoinedNamespaces = .shared
    ) {
        self.parse = parse
        self.redeem = redeem
        self.redeemer = redeemer
        self.confirm = confirm
        self.onJoined = onJoined
        self.capture = capture
        self.justJoined = justJoined
        if enabled { enable() }
    }

    /// Start taking invitations (buffered ones arrive now).
    public func enable() {
        guard cancel == nil else { return }
        cancel = capture.onInvitation { [weak self] captured in self?.receive(captured) }
    }

    /// Stop taking invitations; one already captured stays buffered.
    public func disable() {
        cancel?()
        cancel = nil
    }

    private func receive(_ captured: CapturedInvitation) {
        pending = captured
        token = captured.token
        guard !attempted.contains(captured.token) else { return }
        // Asking is not joining: a prompt is still owed past the attempt cap.
        guard captured.autoJoin || confirm else { return }
        attempted.insert(captured.token)
        begin(captured)
    }

    private func begin(_ captured: CapturedInvitation) {
        guard let invitation = parse(captured.token, captured.params), !invitation.namespaceId.isEmpty else {
            // Unreadable: retrying cannot help, so ack it rather than replay it forever.
            captured.resolve()
            state = .failed(message: "That invitation could not be read.", reason: .invalid, retryable: false)
            return
        }
        parsed = invitation
        if confirm {
            state = .awaitingConfirmation(teamName: invitation.teamName)
            return
        }
        Task { await perform(captured, invitation) }
    }

    private func perform(_ captured: CapturedInvitation, _ invitation: ParsedInvitation) async {
        state = .joining(teamName: invitation.teamName)
        let outcome = await run(invitation)
        if !outcome.shouldRetain { captured.resolve() }
        switch outcome {
        case .joined(let namespaceId, let teamName):
            justJoined.mark(namespaceId)
            onJoined?(namespaceId, teamName)
            state = .joined(namespaceId: namespaceId, teamName: teamName)
        case .alreadyMember(let namespaceId, let teamName):
            justJoined.mark(namespaceId)
            onJoined?(namespaceId, teamName)
            state = .alreadyMember(namespaceId: namespaceId, teamName: teamName)
        case .failed(_, let message, let reason, let retryable):
            state = .failed(message: message, reason: reason, retryable: retryable)
        }
    }

    /// The app's flow, else the standard join.
    private func run(_ invitation: ParsedInvitation) async -> RedeemOutcome {
        if let redeem { return await redeem(invitation) }
        if let redeemer {
            return await redeemInvitation(
                RedeemRequest(
                    namespaceId: invitation.namespaceId, invitation: invitation.invitation,
                    teamName: invitation.teamName),
                redeemer: redeemer)
        }
        return .failed(
            namespaceId: invitation.namespaceId,
            message: "This app cannot redeem invitations: no redeemer is configured.", reason: .unknown,
            retryable: false)
    }

    /// Go ahead with a join that is awaiting confirmation.
    public func accept() {
        guard let captured = pending, let invitation = parsed else { return }
        Task { await perform(captured, invitation) }
    }

    /// Decline, and ack it so the same prompt does not return every launch.
    public func decline() {
        pending?.resolve()
        state = .idle
    }

    /// Retry the captured invitation by hand, past the automatic cap. One the
    /// person already said yes to joins straight away.
    public func retry() {
        guard let captured = pending else { return }
        attempted.insert(captured.token)
        if let invitation = parsed {
            Task { await perform(captured, invitation) }
        } else {
            begin(captured)
        }
    }

    /// Take the result off the screen.
    public func dismiss() {
        state = .idle
    }
}
