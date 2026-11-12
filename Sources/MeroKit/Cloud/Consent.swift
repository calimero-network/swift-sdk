import Foundation

// The consent helper: every kind core's consent page decides, with a typed
// outcome per kind. (== mero-js `client.consent.request / begin / resume / wait`.)
//
// An app's package-bound session may not create an organization, mint or
// accept an invite, approve a release, upgrade an instance or open outbound
// hosts on its own: it asks the node (`POST /consent/requests`, sealed), shows
// the person the answer's `code`, and sends them to the answer's `url`, the
// node's own page, which takes the passkey. The page sends them back to
// `returnTo?request_id=…&result=approved|declined`, and
// `GET /consent/{id}/result` (sealed, same account) says what was decided and,
// for the kinds that make something, what it made (`outcome`).
//
// The bodies are typed here, not by the generated `MeroAPI` types: the
// vendored OpenAPI document predates `createOrg`, `createInvite` and
// `acceptInvite` (calimero-network/core#5014), and the generated decoder
// refuses a `kind` it does not know. Once the document has them, these keep
// working unchanged.
//
// An invite token is a bearer credential: nothing here writes it to a
// description, a debug description or a mirror (`print`, `dump`, os_log
// interpolation), and no error carries it.

/// What a consent request asks for (its `kind`). Open-ended: a node may answer
/// a kind newer than this SDK. (== mero-js `ConsentKind`.)
public struct ConsentKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// Approve (or withdraw) a mero-tee release for a scope.
    public static let release = ConsentKind(rawValue: "release")
    /// Upgrade an app instance to a newer release of its package.
    public static let upgrade = ConsentKind(rawValue: "upgrade")
    /// Approve outbound URL prefixes.
    public static let outbound = ConsentKind(rawValue: "outbound")
    /// Create an organization; the outcome is its id.
    public static let createOrg = ConsentKind(rawValue: "createOrg")
    /// Mint an invite to an organization; the outcome is its token.
    public static let createInvite = ConsentKind(rawValue: "createInvite")
    /// Join an organization with an invite token; the outcome is the organization.
    public static let acceptInvite = ConsentKind(rawValue: "acceptInvite")
}

/// What the app asks its user to approve on the node's consent page, without
/// the `returnTo` (``CalimeroClient/Consent/request(_:returnTo:)`` takes it).
/// (== mero-js `ConsentAsk`.)
public enum ConsentAsk: Sendable, Equatable {
    /// Approve mero-tee release `version` for `scope` (or, `withdraw`, withdraw its approval).
    case release(scope: ConsentScope, version: String, withdraw: Bool = false)
    /// Upgrade `app` to `toVersion`.
    case upgrade(app: String, toVersion: String)
    /// Approve outbound URL prefixes (`nil`: every one the latest release declares).
    case outbound(scope: ConsentScope, package: String? = nil, prefixes: [String]? = nil)
    /// Create an organization named `name`. Outcome: ``ConsentOutcome/orgCreated(orgId:)``.
    case createOrg(name: String)
    /// Mint an invite to `org` with `role`, optionally into `teams`, living
    /// `ttlSecs`, redeemable `uses` times, and (`allApps`) granting every app
    /// of the organization. Outcome: ``ConsentOutcome/inviteCreated(token:)``.
    case createInvite(
        org: String, role: OrgRole, teams: [String]? = nil, ttlSecs: Int? = nil, uses: Int? = nil,
        allApps: Bool? = nil)
    /// Join the organization `token` invites to. Outcome: ``ConsentOutcome/inviteAccepted(org:)``.
    case acceptInvite(token: String)

    /// The request's `kind`.
    public var kind: ConsentKind {
        switch self {
        case .release: return .release
        case .upgrade: return .upgrade
        case .outbound: return .outbound
        case .createOrg: return .createOrg
        case .createInvite: return .createInvite
        case .acceptInvite: return .acceptInvite
        }
    }

    /// The body of `POST /consent/requests`: `{ kind, scope?, subject, returnTo }`.
    public func body(returnTo: String) -> JSONValue {
        var body: [String: JSONValue] = ["kind": .string(kind.rawValue), "returnTo": .string(returnTo)]
        switch self {
        case .release(let scope, let version, let withdraw):
            var subject: [String: JSONValue] = ["version": .string(version)]
            if withdraw { subject["withdraw"] = true }
            body["scope"] = scope.json
            body["subject"] = .object(subject)
        case .upgrade(let app, let toVersion):
            body["subject"] = ["app": .string(app), "toVersion": .string(toVersion)]
        case .outbound(let scope, let package, let prefixes):
            var subject: [String: JSONValue] = [:]
            if let package { subject["package"] = .string(package) }
            if let prefixes { subject["prefixes"] = .array(prefixes.map { .string($0) }) }
            body["scope"] = scope.json
            body["subject"] = .object(subject)
        case .createOrg(let name):
            body["subject"] = ["name": .string(name)]
        case .createInvite(let org, let role, let teams, let ttlSecs, let uses, let allApps):
            var subject: [String: JSONValue] = ["org": .string(org), "role": .string(role.rawValue)]
            if let teams { subject["teams"] = .array(teams.map { .string($0) }) }
            if let ttlSecs { subject["ttlSecs"] = .number(Double(ttlSecs)) }
            if let uses { subject["uses"] = .number(Double(uses)) }
            if let allApps { subject["allApps"] = .bool(allApps) }
            body["subject"] = .object(subject)
        case .acceptInvite(let token):
            body["subject"] = ["token": .string(token)]
        }
        return .object(body)
    }

    /// Refuses what the node would refuse, before anything is sent.
    func validate() throws {
        switch self {
        case .createOrg(let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AccountError.invalidInput("an organization needs a name")
            }
        case .createInvite(let org, let role, _, let ttlSecs, let uses, _):
            guard !org.isEmpty else { throw AccountError.invalidInput("an invite needs an organization") }
            guard role != .owner else { throw AccountError.invalidInput("an invite is for a guest, member or admin") }
            if let ttlSecs, ttlSecs < 0 { throw AccountError.invalidInput("ttlSecs is not negative") }
            if let uses, uses < 0 { throw AccountError.invalidInput("uses is not negative") }
        case .acceptInvite(let token):
            guard !token.isEmpty else { throw AccountError.invalidInput("an invite token is needed") }
        case .release, .upgrade, .outbound:
            break
        }
    }
}

extension ConsentAsk: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The ask, with an invite token redacted.
    public var description: String {
        switch self {
        case .release(let scope, let version, let withdraw):
            return "release(\(scope), \(version)\(withdraw ? ", withdraw" : ""))"
        case .upgrade(let app, let toVersion): return "upgrade(\(app) → \(toVersion))"
        case .outbound(let scope, let package, let prefixes):
            return "outbound(\(scope), package: \(package ?? "-"), prefixes: \(prefixes?.count ?? 0))"
        case .createOrg(let name): return "createOrg(\(name))"
        case .createInvite(let org, let role, _, _, _, _): return "createInvite(\(org), \(role.rawValue))"
        case .acceptInvite: return "acceptInvite(token: <redacted>)"
        }
    }

    public var debugDescription: String { "ConsentAsk.\(description)" }

    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

/// What an approved consent request made: the kinds that create something
/// answer it in `/consent/{id}/result`'s `outcome`. (== mero-js `ConsentOutcome`.)
public enum ConsentOutcome: Sendable, Equatable {
    /// `createOrg`: the new organization.
    case orgCreated(orgId: String)
    /// `createInvite`: the invite's token, a bearer credential. Never log it.
    case inviteCreated(token: String)
    /// `acceptInvite`: the organization joined.
    case inviteAccepted(org: String)

    /// The outcome a `kind` answers in `outcome`, or `nil` (a kind that makes
    /// nothing, or an outcome without the field its kind names).
    init?(kind: ConsentKind, json: JSONValue?) {
        guard let json else { return nil }
        switch kind {
        case .createOrg:
            guard let id = json["orgId"]?.stringValue else { return nil }
            self = .orgCreated(orgId: id)
        case .createInvite:
            guard let token = json["token"]?.stringValue else { return nil }
            self = .inviteCreated(token: token)
        case .acceptInvite:
            guard let org = json["org"]?.stringValue else { return nil }
            self = .inviteAccepted(org: org)
        default:
            return nil
        }
    }
}

extension ConsentOutcome: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The outcome, with an invite token redacted.
    public var description: String {
        switch self {
        case .orgCreated(let orgId): return "orgCreated(\(orgId))"
        case .inviteCreated: return "inviteCreated(token: <redacted>)"
        case .inviteAccepted(let org): return "inviteAccepted(\(org))"
        }
    }

    public var debugDescription: String { "ConsentOutcome.\(description)" }

    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

/// `GET /consent/{id}/result`, with the outcome typed by kind. (== mero-js `ConsentDecision`.)
public struct ConsentDecision: Sendable, Equatable {
    public var requestId: String
    public var kind: ConsentKind
    public var status: ConsentStatus
    /// Unix seconds; `nil` while pending.
    public var decidedAt: Double?
    /// What the approval made (`createOrg`, `createInvite`, `acceptInvite`);
    /// `nil` while pending, when declined, and for the other kinds.
    public var outcome: ConsentOutcome?

    public init(
        requestId: String, kind: ConsentKind, status: ConsentStatus, decidedAt: Double? = nil,
        outcome: ConsentOutcome? = nil
    ) {
        self.requestId = requestId
        self.kind = kind
        self.status = status
        self.decidedAt = decidedAt
        self.outcome = outcome
    }

    /// The node's answer. Throws a ``AccountError/protocolViolation(_:)``
    /// (which never quotes the answer) when a field is missing, or an approved
    /// `createOrg`, `createInvite` or `acceptInvite` has no outcome.
    public init(json: JSONValue) throws {
        guard let requestId = json["requestId"]?.stringValue, let kind = json["kind"]?.stringValue,
            let status = json["status"]?.stringValue.flatMap(ConsentStatus.init(rawValue:))
        else { throw AccountError.protocolViolation("a consent result needs requestId, kind and status") }
        let typed = ConsentKind(rawValue: kind)
        let outcome = ConsentOutcome(kind: typed, json: json["outcome"])
        let makes: [ConsentKind] = [.createOrg, .createInvite, .acceptInvite]
        if status == .approved, outcome == nil, makes.contains(typed) {
            throw AccountError.protocolViolation("an approved \(kind) consent has no outcome")
        }
        self.init(
            requestId: requestId, kind: typed, status: status, decidedAt: json["decidedAt"]?.doubleValue,
            outcome: outcome)
    }

    /// Whether the person approved.
    public var isApproved: Bool { status == .approved }
    /// Whether the person decided (approved or declined).
    public var isDecided: Bool { status != .pending }

    /// `createOrg`, approved: the new organization's id.
    public var orgId: String? {
        if case .orgCreated(let id) = outcome { return id }
        return nil
    }

    /// `createInvite`, approved: the invite's token. A bearer credential: never log it.
    public var inviteToken: String? {
        if case .inviteCreated(let token) = outcome { return token }
        return nil
    }

    /// `acceptInvite`, approved: the organization joined.
    public var joinedOrg: String? {
        if case .inviteAccepted(let org) = outcome { return org }
        return nil
    }

    /// This decision as ``ConsentResult`` (no outcome).
    public var result: ConsentResult {
        ConsentResult(requestId: requestId, kind: kind.rawValue, status: status, decidedAt: decidedAt)
    }
}

extension ConsentDecision: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The decision, with an invite token redacted.
    public var description: String {
        "ConsentDecision(\(requestId), \(kind), \(status.rawValue)\(outcome.map { ", \($0)" } ?? ""))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "requestId": requestId, "kind": kind.rawValue, "status": status.rawValue,
                "decidedAt": decidedAt as Any, "outcome": outcome?.description as Any,
            ])
    }
}

extension CalimeroClient.Consent {
    /// Ask the node to ask the person: `POST /consent/requests` (sealed). Show
    /// the answer's `code`, then open its `url` (`MeroKitUI`'s
    /// `ConsentLauncher.begin` does both in `ASWebAuthenticationSession`).
    /// `returnTo` must be the app package's frontend origin or one its signed
    /// manifest names (`links.frontend`, `frontendAliases`): for a native app,
    /// a universal link on such an https origin. Throws
    /// `CONSENT_CODE_MISMATCH` when the node's `code` is not the page's
    /// (``confirmationCode(_:)``). (== mero-js `client.consent.request`.)
    public func request(_ ask: ConsentAsk, returnTo: String) async throws -> ConsentStarted {
        try ask.validate()
        guard !returnTo.isEmpty else { throw AccountError.invalidInput("a consent request needs a returnTo") }
        let answer = try await client.post("/consent/requests", ask.body(returnTo: returnTo))
        let started: ConsentStarted
        do {
            started = try MeroJSON.decode(ConsentStarted.self, from: CanonicalJSON.data(answer))
        } catch {
            throw AccountError.protocolViolation("a consent request answers requestId, url and expiresAt")
        }
        try CalimeroClient.checkConsentCode(started)
        return started
    }

    /// The decision on `requestId`, now: `GET /consent/{id}/result` (sealed,
    /// the account that asked). (== mero-js `client.consent.result`.)
    public func result(requestId: String) async throws -> ConsentDecision {
        guard !requestId.isEmpty else { throw AccountError.invalidInput("a consent request id is needed") }
        let id = requestId.addingPercentEncoding(withAllowedCharacters: .urlPathSegment) ?? requestId
        return try ConsentDecision(json: try await client.get("/consent/\(id)/result"))
    }

    /// The page sent the person back to `url` (`returnTo?request_id=…&result=…`,
    /// a universal link or the auth session's callback): the node's decision on
    /// that request, or `nil` when `url` is not a consent return. The query is
    /// a hint only; the answer is the node's. Check `requestId` is one this app
    /// started. (== mero-js `client.consent.resume`.)
    public func resume(url: URL) async throws -> ConsentDecision? {
        guard let back = consentReturn(url) else { return nil }
        return try await result(requestId: back.requestId)
    }

    /// Poll `/consent/{id}/result` every `interval` seconds until the request
    /// is decided or `timeout` seconds pass (a request lives 10 minutes), and
    /// answer the last decision: `pending` when it timed out. Throws
    /// `CancellationError` when the task is cancelled. (== mero-js `client.consent.wait`.)
    public func wait(requestId: String, timeout: Double = 600, interval: Double = 2) async throws -> ConsentDecision {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            let decision = try await result(requestId: requestId)
            if decision.isDecided || Date() >= deadline { return decision }
            try Task.checkCancellation()
            await client.sleep(max(0.1, min(interval, deadline.timeIntervalSinceNow)))
            try Task.checkCancellation()
        }
    }
}
