import Foundation

// Release and upgrade approvals as core's node reports them, and the consent
// page an app sends its user to when one is theirs to make. Port of mero-js
// `cloud-v2/approvals.ts`.
//
// An app never approves in its own page: a passkey assertion is blind, so the
// node refuses every approval route to a session opened on an app's frontend
// and serves its own consent page instead. The app asks for a request
// (`POST /consent/requests`), sends the person to the page's `url` (on iOS:
// the system browser, `MeroKitUI`'s `ConsentPage`), and reads the decision
// when the page sends them back (`returnTo?request_id=…&result=…`) or from
// `GET /consent/{id}/result`.

/// Who holds one decision on a cluster (core's `Authority`). (== mero-js `Authority`.)
public enum Authority: String, Codable, Sendable {
    case owner, `operator`
}

/// Core's `Governance`: which side holds each decision on this cluster.
public struct Governance: Codable, Sendable, Equatable {
    public var releases: Authority
    public var appUpgrades: Authority
    public var outbound: Authority
}

/// Whose approvals a report covers: an organization's, or the account's own apps.
public enum ReportScope: Codable, Sendable, Equatable {
    case account
    case org(String)

    enum CodingKeys: String, CodingKey { case kind, org }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .kind) == "org" {
            self = .org(try c.decode(String.self, forKey: .org))
        } else {
            self = .account
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .account: try c.encode("account", forKey: .kind)
        case .org(let org):
            try c.encode("org", forKey: .kind)
            try c.encode(org, forKey: .org)
        }
    }
}

/// A package release as a report names it.
public struct ReportedRelease: Codable, Sendable, Equatable {
    public var package: String
    public var version: String
    public var service: String?
}

/// One replica of an app: its node, the node's attested release, and whether the app's set approves it.
public struct ReportedReplica: Codable, Sendable, Equatable {
    public var node: Int
    public var release: String?
    public var approved: Bool
}

/// One app in a report. (== mero-js `ReportedApp`; `lastUpgrade` kept as JSON.)
public struct ReportedApp: Codable, Sendable, Equatable {
    public var app: String
    public var group: Int
    public var scope: ReportScope
    public var bundle: String
    public var package: ReportedRelease?
    public var upgradesHeldBy: Authority
    public var lastUpgrade: JSONValue?
    public var approvedReleases: [String]?
    public var replicas: [ReportedReplica]
    public var name: String?
    public var team: String?
    public var availableVersions: [String]?
}

/// A mero-tee release the cluster's nodes run, with how many and whether the scope approved it.
public struct ClusterRelease: Codable, Sendable, Equatable {
    public var release: String
    public var nodes: Int
    public var approved: Bool
}

/// `GET /auth/apps` or `GET /orgs/{org}/apps`: one page. (== mero-js `AppsReport`.)
public struct AppsReport: Codable, Sendable, Equatable {
    public var scope: ReportScope
    public var governance: Governance
    public var approvedReleases: [String]?
    public var clusterReleases: [ClusterRelease]
    public var apps: [ReportedApp]
    /// Pass as `after` for the next page; `nil` on the last.
    public var next: String?
}

/// A page of a report. (== mero-js `PageOptions`.)
public struct PageOptions: Sendable, Equatable {
    public var after: String?
    /// 1 to ``maxReportPage``.
    public var limit: Int?

    public init(after: String? = nil, limit: Int? = nil) {
        self.after = after
        self.limit = limit
    }

    /// `?after=&limit=`; a `limit` outside 1 to 100 is refused before sending. (== mero-js `pageQuery`.)
    public func query() throws -> String {
        var items: [String] = []
        if let after {
            items.append("after=\(after.addingPercentEncoding(withAllowedCharacters: .urlQueryValue) ?? after)")
        }
        if let limit {
            guard (1...maxReportPage).contains(limit) else {
                throw AccountError.invalidInput("limit is 1 to \(maxReportPage)")
            }
            items.append("limit=\(limit)")
        }
        return items.isEmpty ? "" : "?" + items.joined(separator: "&")
    }
}

/// The most entries one page of a report answers. (== mero-js `MAX_REPORT_PAGE`.)
public let maxReportPage = 100

/// A release's end-of-new-work deadline. (== mero-js `ReleaseDeadline`.)
public struct ReleaseDeadline: Codable, Sendable, Equatable {
    public var version: String
    /// RFC 3339.
    public var after: String
    /// Unix seconds.
    public var afterSecs: Double
}

/// `GET /releases`. (== mero-js `ReleaseRules`.)
public struct ReleaseRules: Codable, Sendable, Equatable {
    public var governance: Governance
    public var deadlines: [ReleaseDeadline]
}

/// Whether a scope whose approved set is `approved` has lost new work at
/// `now` (Unix seconds): a release's deadline has passed and the newest
/// approved release is older. (== mero-js `stalledBy`.)
public func stalledBy(
    _ approved: [String]?, deadlines: [ReleaseDeadline], now: Double = Date().timeIntervalSince1970
) -> ReleaseDeadline? {
    guard let approved, let newest = approved.max(by: { compareVersions($0, $1) < 0 }) else { return nil }
    var stall: ReleaseDeadline?
    for d in deadlines where d.afterSecs <= now && compareVersions(newest, d.version) < 0 {
        if stall == nil || compareVersions(d.version, stall!.version) > 0 { stall = d }
    }
    return stall
}

/// `GET /publishers/{signerId}`. (== mero-js `PublisherBindingInfo`.)
public struct PublisherBindingInfo: Codable, Sendable, Equatable {
    public var signerId: String
    public var cluster: String
    public var generation: Int
    public var bound: Bool
}

/// `POST /orgs/{org}/publishers`: the key's proof, base64url. (== mero-js `PublisherProof`.)
public struct PublisherProof: Codable, Sendable, Equatable {
    public var signerId: String
    public var publicKey: String
    public var signature: String

    public init(signerId: String, publicKey: String, signature: String) {
        self.signerId = signerId
        self.publicKey = publicKey
        self.signature = signature
    }
}

/// The text a package signing key signs to bind it to `org` as its
/// publisher. (== mero-js `publisherBindingMessage`.)
public func publisherBindingMessage(cluster: String, org: String, signerId: String, generation: Int) -> String {
    "calimero-publisher-binding/v1\n\(cluster)\n\(org)\n\(signerId)\n\(generation)"
}

// MARK: - The consent page

/// Whose approval a release or outbound request is for. (== mero-js `ConsentScope`.)
public enum ConsentScope: Sendable, Equatable {
    case account
    case org(String)

    var json: JSONValue {
        switch self {
        case .account: return "account"
        case .org(let org): return ["org": .string(org)]
        }
    }
}

/// What the app asks its user to approve (`POST /consent/requests`). (== mero-js `ConsentRequest`.)
public enum ConsentRequest: Sendable, Equatable {
    /// Approve mero-tee release `version` (or, `withdraw`, withdraw its approval).
    case release(scope: ConsentScope, version: String, withdraw: Bool = false, returnTo: String)
    /// Upgrade `app` to `toVersion`.
    case upgrade(app: String, toVersion: String, returnTo: String)
    /// Approve outbound URL prefixes (`nil`: every one the latest release declares).
    case outbound(scope: ConsentScope, package: String? = nil, prefixes: [String]? = nil, returnTo: String)

    public var json: JSONValue {
        switch self {
        case .release(let scope, let version, let withdraw, let returnTo):
            var subject: [String: JSONValue] = ["version": .string(version)]
            if withdraw { subject["withdraw"] = true }
            return [
                "kind": "release", "scope": scope.json, "subject": .object(subject), "returnTo": .string(returnTo),
            ]
        case .upgrade(let app, let toVersion, let returnTo):
            return [
                "kind": "upgrade", "subject": ["app": .string(app), "toVersion": .string(toVersion)],
                "returnTo": .string(returnTo),
            ]
        case .outbound(let scope, let package, let prefixes, let returnTo):
            var subject: [String: JSONValue] = [:]
            if let package { subject["package"] = .string(package) }
            if let prefixes { subject["prefixes"] = .array(prefixes.map { .string($0) }) }
            return [
                "kind": "outbound", "scope": scope.json, "subject": .object(subject), "returnTo": .string(returnTo),
            ]
        }
    }
}

/// The node's answer to a consent request: send the person to `url`. (== mero-js `ConsentStarted`.)
public struct ConsentStarted: Codable, Sendable, Equatable {
    public var requestId: String
    /// The consent page, on the node's own origin.
    public var url: String
    /// Unix seconds; a request lives 10 minutes.
    public var expiresAt: Double
    /// The confirmation code the consent page shows (`ABC-DEF`, core's
    /// `confirmation_code`). Show it in the app before opening the page, so
    /// the person can check the page is the one the app asked for. `nil`
    /// from a node that predates it.
    public var code: String?
}

/// `pending`, `approved` or `declined`. (== mero-js `ConsentStatus`.)
public enum ConsentStatus: String, Codable, Sendable {
    case pending, approved, declined
}

/// `GET /consent/{id}/result`. (== mero-js `ConsentResult`.)
public struct ConsentResult: Codable, Sendable, Equatable {
    public var requestId: String
    public var kind: String
    public var status: ConsentStatus
    public var decidedAt: Double?
}

/// What the consent page put on `returnTo` when it sent the person back, or
/// `nil`. A hint only: confirm with ``CalimeroClient/consentResult(_:)``.
/// (== mero-js `consentReturn`.)
public func consentReturn(_ url: URL) -> (requestId: String, approved: Bool)? {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let id = items.first(where: { $0.name == "request_id" })?.value, !id.isEmpty,
        let result = items.first(where: { $0.name == "result" })?.value, result == "approved" || result == "declined"
    else { return nil }
    return (id, result == "approved")
}

/// The consent request that approves `version` for `scope`. (== mero-js `releaseConsent`.)
public func releaseConsent(
    _ scope: ReportScope, version: String, returnTo: String, withdraw: Bool = false
)
    -> ConsentRequest
{
    let consentScope: ConsentScope
    switch scope {
    case .account: consentScope = .account
    case .org(let org): consentScope = .org(org)
    }
    return .release(scope: consentScope, version: version, withdraw: withdraw, returnTo: returnTo)
}

/// The consent request that withdraws `version`'s approval. (== mero-js `withdrawConsent`.)
public func withdrawConsent(_ scope: ReportScope, version: String, returnTo: String) -> ConsentRequest {
    releaseConsent(scope, version: version, returnTo: returnTo, withdraw: true)
}

/// The consent request that upgrades `app` to `toVersion`. (== mero-js `upgradeConsent`.)
public func upgradeConsent(app: String, toVersion: String, returnTo: String) -> ConsentRequest {
    .upgrade(app: app, toVersion: toVersion, returnTo: returnTo)
}

/// A mero-tee release's notes on GitHub. (== mero-js `releaseNotesUrl`.)
public func releaseNotesUrl(_ version: String) -> String {
    "https://github.com/calimero-network/mero-tee/releases/tag/mero-tee-v\(version)"
}

/// The public verifier's page for a mero-tee release. (== mero-js `verifyReleaseUrl`.)
public func verifyReleaseUrl(_ version: String) -> String {
    "https://mero-tee.vercel.app/mero-tee?release_tag=mero-tee-v\(version)"
}

/// A mero-tee release the cluster's nodes run that the scope has not approved.
public struct PendingRelease: Sendable, Equatable {
    public var version: String
    public var nodes: Int
    /// Whether the scope's side holds release approvals (else the operator does).
    public var actionable: Bool
    public var releaseNotesUrl: String
    public var verifyUrl: String
    public var deadline: ReleaseDeadline?
}

/// An app with newer releases of its package.
public struct PendingUpgrade: Sendable, Equatable {
    public var app: String
    public var name: String?
    public var package: String
    public var from: String
    /// The newest it may move to.
    public var to: String
    public var available: [String]
    public var actionable: Bool
}

/// What ``CalimeroClient/pendingApprovals(org:)`` answers. (== mero-js `PendingApprovals`.)
public struct PendingApprovals: Sendable, Equatable {
    public var scope: ReportScope
    public var governance: Governance
    public var approvedReleases: [String]?
    public var releases: [PendingRelease]
    public var upgrades: [PendingUpgrade]
    public var stalledBy: ReleaseDeadline?
    /// Whether anything here is the user's to approve.
    public var actionable: Bool
}

/// The pending list from a scope's report and the cluster's release rules.
/// (== mero-js `pendingApprovalsFrom`.)
public func pendingApprovalsFrom(
    _ report: AppsReport, rules: ReleaseRules, now: Double = Date().timeIntervalSince1970
) -> PendingApprovals {
    let releasesActionable = report.governance.releases == .owner
    let upgradesActionable = report.governance.appUpgrades == .owner
    let releases = report.clusterReleases.filter { !$0.approved }
        .sorted { compareVersions($0.release, $1.release) > 0 }
        .map { r in
            PendingRelease(
                version: r.release, nodes: r.nodes, actionable: releasesActionable,
                releaseNotesUrl: releaseNotesUrl(r.release), verifyUrl: verifyReleaseUrl(r.release),
                deadline: rules.deadlines.first { $0.version == r.release })
        }
    let upgrades: [PendingUpgrade] = report.apps.compactMap { a in
        guard let package = a.package, let available = a.availableVersions, let to = available.last else {
            return nil
        }
        return PendingUpgrade(
            app: a.app, name: a.name, package: package.package, from: package.version, to: to, available: available,
            actionable: upgradesActionable)
    }
    return PendingApprovals(
        scope: report.scope, governance: report.governance, approvedReleases: report.approvedReleases,
        releases: releases, upgrades: upgrades,
        stalledBy: stalledBy(report.approvedReleases, deadlines: rules.deadlines, now: now),
        actionable: releases.contains { $0.actionable } || upgrades.contains { $0.actionable })
}

extension CharacterSet {
    /// What may stand unescaped in a query value.
    static let urlQueryValue: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()

    /// What may stand unescaped in one path segment.
    static let urlPathSegment: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()
}
