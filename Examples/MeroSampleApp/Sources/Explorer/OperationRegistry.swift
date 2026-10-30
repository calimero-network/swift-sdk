import Foundation
import MeroKit

// The Calimero 1.0 client surface, one `SDKOperation` per `CalimeroClient`
// method worth trying from a phone. Request bodies are entered as JSON;
// results are pretty-printed. Every call goes through the attested, sealed
// channel the session opened.

private func field(_ inputs: [String: String], _ key: String) throws -> String {
    guard let value = inputs.opt(key) else { throw AccountError.invalidInput("\(key) is required") }
    return value
}

// MARK: Account

private let accountOps: [SDKOperation] = [
    SDKOperation("me", "Account", "me", "Your account, passkeys and organizations") { c, _ in
        Fmt.json(try await c.me().raw)
    },
    SDKOperation("usage", "Account", "usage", "What the account uses, with the cluster's quotas") { c, _ in
        Fmt.json(try await c.usage())
    },
    SDKOperation("refresh", "Account", "refresh", "Swap the refresh token for a new session") { c, _ in
        let session = try await c.refresh()
        return "Refreshed: session for \(session.accountId), expires \(Date(timeIntervalSince1970: session.expiresAt))"
    },
    SDKOperation("attestation", "Account", "attestation", "The node's attestation document (display only)") { c, _ in
        Fmt.json(try await c.attestation())
    },
    SDKOperation("apikeys", "Account", "listApiKeys", "The account's API keys (never the keys)") { c, _ in
        Fmt.json(JSONValue.array(try await c.listApiKeys()))
    },
    SDKOperation("aliases", "Account", "aliases", "This account's aliases, alias to app id") { c, _ in
        Fmt.json(try await c.aliases())
    },
]

// MARK: Apps

private let appOps: [SDKOperation] = [
    SDKOperation(
        "apps", "Apps", "listApps", "App instances you reach",
        fields: [.line("package", "Package", "com.calimero.chat")]
    ) { c, i in Fmt.json(try await c.listApps(package: i.opt("package"))) },
    SDKOperation("app", "Apps", "getApp", "One app instance's record", fields: [.line("app", "App id")]) { c, i in
        Fmt.json(try await c.getApp(try field(i, "app")))
    },
    SDKOperation("abi", "Apps", "appAbi", "The ABI the app's bundle embeds", fields: [.line("app", "App id")]) { c, i in
        Fmt.json(try await c.appAbi(try field(i, "app")))
    },
    SDKOperation(
        "view", "Apps", "view", "Run a read-only method (POST /apps/{app}/views)",
        fields: [.line("app", "App id"), .line("method", "Method", "get_messages"), .json("args", "Arguments")]
    ) { c, i in
        Fmt.json(try await c.view(try field(i, "app"), try field(i, "method"), try Fmt.value(i.v("args"))))
    },
    SDKOperation(
        "call", "Apps", "call", "Call a method (POST /apps/{app}/intents), retried with one idempotency key",
        fields: [.line("app", "App id"), .line("method", "Method"), .json("args", "Arguments")]
    ) { c, i in
        Fmt.json(try await c.call(try field(i, "app"), try field(i, "method"), try Fmt.value(i.v("args"))))
    },
    SDKOperation(
        "create", "Apps", "createApp", "Create an app instance of a package release",
        fields: [
            .line("name", "Name"), .line("package", "Package", "com.calimero.chat"), .line("version", "Version"),
            .line("org", "Org id"),
        ]
    ) { c, i in
        let app = try await c.createApp(
            try field(i, "name"), bundle: .package(try field(i, "package"), version: i.opt("version")),
            org: i.opt("org"), initArgs: [:])
        return "Created app \(app)"
    },
    SDKOperation("blobs", "Apps", "listBlobs", "An app's blobs", fields: [.line("app", "App id")]) { c, i in
        Fmt.json(try await c.listBlobs(try field(i, "app")))
    },
    SDKOperation("presence", "Apps", "presence", "Who is present in an app", fields: [.line("app", "App id")]) { c, i in
        Fmt.json(try await c.presence(try field(i, "app")))
    },
    SDKOperation("packages", "Apps", "packages", "Installed packages and their versions") { c, _ in
        Fmt.json(try await c.packages())
    },
]

// MARK: Organizations

private let orgOps: [SDKOperation] = [
    SDKOperation("org.create", "Organizations", "createOrg", "Create an organization", fields: [.line("name", "Name")])
    { c, i in
        "Created org \(try await c.createOrg(try field(i, "name")))"
    },
    SDKOperation(
        "org.get", "Organizations", "getOrg", "An organization and its teams", fields: [.line("org", "Org id")]
    ) { c, i in
        Fmt.json(try await c.getOrg(try field(i, "org")).raw)
    },
    SDKOperation(
        "team.create", "Organizations", "createTeam", "Create a team (open: everyone may join)",
        fields: [.line("org", "Org id"), .line("name", "Name"), .line("join", "everyone or invite", "everyone")]
    ) { c, i in
        let join = TeamJoin(rawValue: i.opt("join") ?? "everyone") ?? .everyone
        return "Created team \(try await c.createTeam(try field(i, "org"), name: try field(i, "name"), join: join))"
    },
    SDKOperation(
        "team.get", "Organizations", "getTeam", "A team, its members and apps",
        fields: [.line("org", "Org id"), .line("team", "Team id")]
    ) { c, i in Fmt.json(try await c.getTeam(try field(i, "org"), try field(i, "team")).raw) },
    SDKOperation(
        "invite", "Organizations", "invite", "Mint an invite token", fields: [.line("org", "Org id")]
    ) { c, i in "Invite token: \(try await c.invite(try field(i, "org")))" },
    SDKOperation(
        "redeem", "Organizations", "redeemInvite", "Join an organization with an invite token",
        fields: [.line("token", "Token", "inv_…")]
    ) { c, i in Fmt.json(try await c.redeemInvite(try field(i, "token"))) },
]

// MARK: Approvals

private let approvalOps: [SDKOperation] = [
    SDKOperation(
        "pending", "Approvals", "pendingApprovals", "Releases and upgrades waiting for a decision",
        fields: [.line("org", "Org id (empty: your own apps)")]
    ) { c, i in
        let pending = try await c.pendingApprovals(org: i.opt("org"))
        let releases = pending.releases.map { "release \($0.version) on \($0.nodes) node(s)" }
        let upgrades = pending.upgrades.map { "upgrade \($0.name ?? $0.app): \($0.from) to \($0.to)" }
        let lines = releases + upgrades
        return lines.isEmpty ? "Nothing waits for a decision." : lines.joined(separator: "\n")
    },
    SDKOperation("rules", "Approvals", "releaseRules", "The cluster's governance and release deadlines") { c, _ in
        Fmt.json(try await c.releaseRules())
    },
    SDKOperation(
        "consent.result", "Approvals", "consentResult", "The decision on a consent request",
        fields: [.line("request", "Request id")]
    ) { c, i in Fmt.json(try await c.consentResult(try field(i, "request"))) },
]

let sdkOperations: [SDKOperation] = accountOps + appOps + orgOps + approvalOps

/// Categories in display order (as first seen in `sdkOperations`).
let sdkCategories: [String] = {
    var seen: [String] = []
    for op in sdkOperations where !seen.contains(op.category) { seen.append(op.category) }
    return seen
}()
