import Foundation
import MeroKit

#if canImport(SwiftUI)
import SwiftUI
#endif

/// How long "You're in" stays up before the dialog closes by itself.
/// (== mero-react `INVITATION_READY_MS`, in seconds.)
public let invitationReadyDelay: TimeInterval = 1.2

/// The stage ``InvitationDialog`` shows: the redemption's, plus the wait for
/// the joined namespace's data. (== mero-react `InvitationDialogStage`.)
public enum InvitationDialogStage: String, Sendable, Equatable {
    case awaitingConfirmation = "awaiting-confirmation"
    case joining
    case syncing
    case ready
    case alreadyMember = "already-member"
    case failed

    /// The stage for `state`, or `nil` when there is nothing to show. A join
    /// is `syncing` while its namespace's just-joined flag is set.
    public static func resolve(_ state: InviteState, flagged: Bool) -> InvitationDialogStage? {
        switch state {
        case .idle: return nil
        case .awaitingConfirmation: return .awaitingConfirmation
        case .joining: return .joining
        case .joined: return flagged ? .syncing : .ready
        case .alreadyMember: return .alreadyMember
        case .failed: return .failed
        }
    }

    /// Mid-join and mid-sync a stray tap must not close the dialog.
    public var isBusy: Bool { self == .joining || self == .syncing }
}

/// The words for one stage. (mero-react's `InvitationDialog` copy.)
public struct InvitationDialogCopy: Equatable, Sendable {
    public let title: String
    public let body: String?

    public static func make(
        stage: InvitationDialogStage, state: InviteState, noun: String = "team", detail: String? = nil,
        status: String? = nil, slow: Bool = false
    ) -> InvitationDialogCopy {
        let teamName = state.teamName
        let named = teamName.map { "“\($0)”" } ?? "this \(noun)"
        switch stage {
        case .awaitingConfirmation:
            let ask =
                "You have been invited. Joining makes this device a member, and the \(noun)'s data syncs to it "
                + "from the other members."
            let title = teamName.map { "Join “\($0)”?" } ?? "Join this \(noun)?"
            return InvitationDialogCopy(title: title, body: detail ?? ask)
        case .joining:
            let fallback = "Asking a member to let you in. With few members online this can take up to a minute."
            let step = status.flatMap { $0.isEmpty ? nil : $0 }
            return InvitationDialogCopy(title: "Joining \(named)…", body: step ?? fallback)
        case .syncing:
            return InvitationDialogCopy(
                title: "Syncing \(named)…",
                body: slow
                    ? "Still waiting on the other members. You can carry on; the \(noun) fills in as its data arrives."
                    : "You're in. Getting the \(noun)'s data from the other members.")
        case .ready:
            return InvitationDialogCopy(title: "You're in \(named)", body: nil)
        case .alreadyMember:
            return InvitationDialogCopy(title: "You're already in \(named)", body: nil)
        case .failed:
            guard case .failed(let message, let reason, _) = state else {
                return InvitationDialogCopy(title: "Couldn't join", body: nil)
            }
            let plain = describeInviteFailure(reason, noun: noun)
            return InvitationDialogCopy(title: "Couldn't join", body: plain ?? message)
        }
    }
}

/// What the logged-out invitation screen shows. (== mero-react `InvitationGate`'s state.)
public enum InvitationGateState: String, Sendable, Equatable {
    /// The session is still restoring: a wordless spinner, no landing flash.
    case checking
    /// Logged out with a readable invitation: "You're invited…".
    case invited
    /// The link cannot be read.
    case invalid

    /// The screen for a pending invitation, or `nil` to show the app.
    public static func resolve(
        hasPending: Bool, parseFailed: Bool, isAuthenticated: Bool, isLoading: Bool
    ) -> InvitationGateState? {
        guard hasPending, !isAuthenticated else { return nil }
        if isLoading { return .checking }
        return parseFailed ? .invalid : .invited
    }
}

#if canImport(SwiftUI)
/// The one invitation prompt: ask, join, wait for the data, done. Put it over
/// the app's root (`.overlay(InvitationDialog(redemption: …))`); it shows
/// nothing until a link has been opened. (== mero-react `InvitationDialog`.)
///
///     awaiting-confirmation  "Join “Design team”?"      Join / Not now
///     joining                "Joining “Design team”…"   (cannot be closed)
///     syncing                "Syncing “Design team”…"   (once slow: Continue in background)
///     ready                  "You're in “Design team”"  closes by itself
///     already-member         "You're already in …"      Done
///     failed                 the reason, in plain words Try again / Close
///
/// `syncing` lasts while the namespace's just-joined flag is set, until the
/// page reading the data clears it (``JoinSync``), the app says ``synced``, or
/// the ceiling passes. Identifiers: `invitePrompt` (value: the stage),
/// `inviteAccept`, `inviteDecline`, `inviteRetry`, `inviteContinue`,
/// `inviteDone`, `inviteError`.
@MainActor
public struct InvitationDialog: View {
    @ObservedObject private var redemption: InviteRedemption
    @ObservedObject private var justJoined: JustJoinedNamespaces
    @Environment(\.meroTheme) private var theme
    @State private var backgroundId: String?
    @State private var slow = false

    private let noun: String
    private let appName: String?
    private let synced: Bool
    private let detail: String?
    private let status: String?

    public init(
        redemption: InviteRedemption, noun: String = "team", appName: String? = nil, synced: Bool = false,
        detail: String? = nil, status: String? = nil, justJoined: JustJoinedNamespaces = .shared
    ) {
        _redemption = ObservedObject(wrappedValue: redemption)
        _justJoined = ObservedObject(wrappedValue: justJoined)
        self.noun = noun
        self.appName = appName
        self.synced = synced
        self.detail = detail
        self.status = status
    }

    private var joinedId: String? {
        if case .joined(let namespaceId, _) = redemption.state { return namespaceId }
        return nil
    }

    /// The namespace still waited on, kept after "Continue in background".
    private var waitingId: String? { joinedId ?? backgroundId }

    private var stage: InvitationDialogStage? {
        InvitationDialogStage.resolve(redemption.state, flagged: joinedId.map { justJoined.contains($0) } ?? false)
    }

    public var body: some View {
        ZStack {
            if let stage {
                theme.overlay
                    .ignoresSafeArea()
                    .onTapGesture { close(stage) }
                    .accessibilityHidden(true)
                card(stage)
            }
        }
        .task(id: waitKey) { await watchSync() }
        .task(id: stage) { await closeWhenReady() }
    }

    private var waitKey: String { "\(waitingId ?? "")|\(justJoined.contains(waitingId))|\(synced)" }

    /// Past the watchdog say so; at the ceiling let go of the flag too.
    private func watchSync() async {
        slow = false
        if let joinedId { backgroundId = joinedId }
        guard let waitingId, justJoined.contains(waitingId) else {
            if joinedId == nil { backgroundId = nil }
            return
        }
        if synced {
            justJoined.clear(waitingId)
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(JoinSync.watchdog * 1_000_000_000))
        guard !Task.isCancelled else { return }
        slow = true
        try? await Task.sleep(nanoseconds: UInt64((JoinSync.maximum - JoinSync.watchdog) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        justJoined.clear(waitingId)
    }

    private func closeWhenReady() async {
        guard stage == .ready else { return }
        try? await Task.sleep(nanoseconds: UInt64(invitationReadyDelay * 1_000_000_000))
        guard !Task.isCancelled, stage == .ready else { return }
        redemption.dismiss()
    }

    private func close(_ stage: InvitationDialogStage) {
        if stage == .awaitingConfirmation {
            redemption.decline()
        } else if !stage.isBusy {
            redemption.dismiss()
        }
    }

    private func card(_ stage: InvitationDialogStage) -> some View {
        let copy = InvitationDialogCopy.make(
            stage: stage, state: redemption.state, noun: noun, detail: detail, status: status, slow: slow)
        return VStack(alignment: .leading, spacing: 14) {
            if let appName {
                Text(appName).font(.caption.weight(.semibold)).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                icon(stage)
                Text(copy.title).font(.headline).accessibilityAddTraits(.isHeader)
            }
            if let body = copy.body {
                Text(body)
                    .font(.subheadline)
                    .foregroundColor(stage == .failed ? theme.error : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(stage == .failed ? "inviteError" : "inviteBody")
            }
            if stage.isBusy {
                ProgressView().progressViewStyle(.linear).tint(theme.primary)
            }
            actions(stage)
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: theme.radius * 1.5))
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("invitePrompt")
        .accessibilityValue(stage.rawValue)
    }

    @ViewBuilder
    private func icon(_ stage: InvitationDialogStage) -> some View {
        switch stage {
        case .joining, .syncing:
            ProgressView()
        case .ready, .alreadyMember:
            Image(systemName: "checkmark.circle.fill").foregroundColor(theme.primary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(theme.error)
        case .awaitingConfirmation:
            Image(systemName: "envelope.fill").foregroundColor(theme.primary)
        }
    }

    @ViewBuilder
    private func actions(_ stage: InvitationDialogStage) -> some View {
        HStack(spacing: 10) {
            Spacer()
            switch stage {
            case .awaitingConfirmation:
                secondary("Not now", id: "inviteDecline") { redemption.decline() }
                primary("Join", id: "inviteAccept") { redemption.accept() }
            case .syncing where slow:
                secondary("Continue in background", id: "inviteContinue") { redemption.dismiss() }
            case .ready, .alreadyMember:
                primary("Done", id: "inviteDone") { redemption.dismiss() }
            case .failed:
                secondary("Close", id: "inviteDecline") { redemption.dismiss() }
                if canRetry {
                    primary("Try again", id: "inviteRetry") { redemption.retry() }
                }
            default:
                EmptyView()
            }
        }
    }

    private var canRetry: Bool {
        if case .failed(_, _, let retryable) = redemption.state { return retryable }
        return false
    }

    private func primary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: theme.radius).fill(theme.primary))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func secondary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id)
    }
}

/// The screen an invite link lands on when nobody is signed in: "You're
/// invited to join “Design team”", with **Not now** (acks it) and **Log in to
/// join** (the usual login). Signed in, it gets out of the way and the
/// ``InvitationDialog`` asks. It reads the captured invitation without taking
/// it, so the app's ``InviteRedemption`` still receives it after login.
/// (== mero-react `InvitationGate`.)
///
/// Identifiers: `inviteLanding` (value: `checking`, `invited` or `invalid`),
/// `inviteLandingLogin`, `inviteLandingDecline`.
@MainActor
public struct InvitationGate<Content: View>: View {
    @EnvironmentObject private var client: MeroClient
    @ObservedObject private var capture: InvitationCapture
    @Environment(\.meroTheme) private var theme
    @State private var showLogin = false

    private let parse: InviteRedemption.Parse?
    private let noun: String
    private let appName: String?
    private let detail: String?
    private let callbackScheme: String
    private let content: Content

    public init(
        callbackScheme: String, parse: InviteRedemption.Parse? = nil, noun: String = "team", appName: String? = nil,
        detail: String? = nil, capture: InvitationCapture = .shared, @ViewBuilder content: () -> Content
    ) {
        self.callbackScheme = callbackScheme
        self.parse = parse
        self.noun = noun
        self.appName = appName
        self.detail = detail
        _capture = ObservedObject(wrappedValue: capture)
        self.content = content()
    }

    public var body: some View {
        let pending = capture.current
        let parsed = pending.flatMap { parse?($0.token, $0.params) }.flatMap { $0.namespaceId.isEmpty ? nil : $0 }
        let state = InvitationGateState.resolve(
            hasPending: pending != nil, parseFailed: parse != nil && parsed == nil,
            isAuthenticated: client.isAuthenticated, isLoading: client.isLoading)
        if let state {
            screen(state, teamName: parsed?.teamName, pending: pending)
                .sheet(isPresented: loginPresented) {
                    LoginView(callbackScheme: callbackScheme).environmentObject(client).meroTheme(theme)
                }
        } else {
            content
        }
    }

    private var loginPresented: Binding<Bool> {
        Binding(get: { showLogin && !client.isAuthenticated }, set: { showLogin = $0 })
    }

    @ViewBuilder
    private func screen(_ state: InvitationGateState, teamName: String?, pending: CapturedInvitation?) -> some View {
        if state == .checking {
            ProgressView()
                .accessibilityLabel("Checking your session")
                .accessibilityIdentifier("inviteLanding")
                .accessibilityValue(state.rawValue)
        } else {
            let copy = Self.copy(state, teamName: teamName, noun: noun, appName: appName)
            VStack(alignment: .leading, spacing: 14) {
                if let appName { Text(appName).font(.caption.weight(.semibold)).foregroundColor(.secondary) }
                Text(copy.title).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(copy.body ?? "").font(.subheadline).foregroundColor(.secondary)
                if let detail, state == .invited { Text(detail).font(.subheadline).foregroundColor(.secondary) }
                HStack {
                    Spacer()
                    if state == .invalid {
                        Button("Continue") { pending?.resolve() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("inviteLandingDecline")
                    } else {
                        Button("Not now") { pending?.resolve() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("inviteLandingDecline")
                        Button("Log in to join") { showLogin = true }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.primary)
                            .foregroundColor(theme.primaryText)
                            .accessibilityIdentifier("inviteLandingLogin")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inviteLanding")
            .accessibilityValue(state.rawValue)
        }
    }

    /// The landing screen's words.
    static func copy(
        _ state: InvitationGateState, teamName: String?, noun: String, appName: String?
    ) -> InvitationDialogCopy {
        if state == .invalid {
            return InvitationDialogCopy(
                title: "This invitation can't be read",
                body: "The link may have been cut short when it was shared. Ask whoever sent it for a new one.")
        }
        let title = teamName.map { "You're invited to join “\($0)”" } ?? "You're invited to join a \(noun)"
        let place = appName.map { " in \($0)" } ?? ""
        return InvitationDialogCopy(
            title: title,
            body: "Someone sent you a link to join this \(noun)\(place). Log in to accept it; you'll be asked to "
                + "confirm before you join.")
    }
}

/// "Joined. Syncing … from peers": usually `JoinSync.isSyncing`, with an
/// optional "Show anyway". Renders nothing when `show` is false. Announced to
/// VoiceOver as it appears. (== mero-react `JoinSyncBanner`.)
///
/// Identifiers: `joinSyncBanner`, `joinSyncDismiss`.
@MainActor
public struct JoinSyncBanner: View {
    private let show: Bool
    private let what: String
    private let onDismiss: (() -> Void)?

    public init(show: Bool, what: String = "data", onDismiss: (() -> Void)? = nil) {
        self.show = show
        self.what = what
        self.onDismiss = onDismiss
    }

    public var body: some View {
        if show {
            HStack(spacing: 10) {
                ProgressView()
                (Text("Joined. Syncing \(what) from peers… ")
                    + Text("This can take a moment on a cold connection.").foregroundColor(.secondary))
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onDismiss {
                    Button("Show anyway", action: onDismiss)
                        .font(.footnote)
                        .accessibilityIdentifier("joinSyncDismiss")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.28)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("joinSyncBanner")
        }
    }
}
#endif
