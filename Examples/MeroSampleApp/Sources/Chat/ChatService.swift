import Foundation
import MeroKit

// MARK: - Wire models (curb contract, snake_case)

/// A single message as returned by curb's `get_messages` / `send_message`.
/// Only the fields the UI needs are decoded; the rest are ignored.
struct ChatMessage: Decodable, Identifiable {
    let id: String
    let text: String
    let senderUsername: String
    let sender: String
    let timestamp: Int
    let deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, text, sender, timestamp, deleted
        case senderUsername = "sender_username"
    }
}

struct ChatMessagePage: Decodable {
    let totalCount: Int
    let messages: [ChatMessage]
    let startPosition: Int

    enum CodingKeys: String, CodingKey {
        case messages
        case totalCount = "total_count"
        case startPosition = "start_position"
    }
}

/// curb `get_info` → the channel/DM shape.
struct ChatContextInfo: Decodable {
    let name: String
    let contextType: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case name, description
        case contextType = "context_type"
    }
}

// MARK: - View models

struct ChatSpace: Identifiable, Equatable {
    let id: String  // namespaceId
    let name: String
    /// The namespace's target application (what a new channel runs).
    var applicationId: String = ""
}

struct ChatChannel: Identifiable, Equatable {
    let id: String  // contextId
    let groupId: String
    let contextId: String
    /// The member identity to execute as — node backend only; a relay writes
    /// as the account, through a warrant.
    let executorId: String
    let name: String
    let kind: String
}

/// Shareable invitation payload — bundles the namespaceId so joining needs no
/// base58 decode of the invitation's raw group-id bytes.
struct ChatInvite: Codable {
    let namespaceId: String
    let spaceName: String
    let invitation: SignedGroupOpenInvitation

    /// A compact, single-line invite code: `base58(deflate(JSON))` via
    /// `InviteCodec`, the format the rest of the fleet uses.
    func encoded() throws -> String {
        try InviteCodec.encode(self)
    }

    /// The shareable link for this invite.
    func shareableLink() throws -> String {
        InviteLink.invitation(token: try encoded(), slug: ChatService.packageName)
    }

    /// Decode an invite code, or a link containing one. Accepts the shared
    /// format, the legacy base64 form, and raw JSON.
    static func decode(_ code: String) -> ChatInvite? {
        guard let token = InviteLink.token(fromPasted: code) else { return nil }

        if let json = InviteCodec.decode(token: token),
            let invite = try? JSONDecoder().decode(ChatInvite.self, from: Data(json.utf8))
        {
            return invite
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed),
            let json = try? (data as NSData).decompressed(using: .zlib) as Data,
            let invite = try? JSONDecoder().decode(ChatInvite.self, from: json)
        {
            return invite
        }
        return try? JSONDecoder().decode(ChatInvite.self, from: Data(trimmed.utf8))
    }
}

// MARK: - ChatService

/// A native curb (mero-chat) frontend: spaces (namespaces), channels
/// (contexts), messages (contract calls), invite and join — on the same WASM
/// contract as mero-chat.
///
/// Two backends:
/// - `.relay`: the Cloud session. Reads go through the relay's query route,
///   writes through warrants; admin listings use the relay's Bearer session;
///   joining redeems an invitation as the account.
/// - `.node`: a development node (e2e harnesses only), over JSON-RPC and admin.
@MainActor
final class ChatService: ObservableObject {
    enum Backend {
        case relay(CloudConnection, CloudSignIn)
        case node(Mero)
    }

    nonisolated static let registryURL = "https://apps.calimero.network"
    nonisolated static let packageName = "com.calimero.curb"

    @Published var appId: String?
    @Published var spaces: [ChatSpace] = []
    @Published var channels: [ChatChannel] = []
    @Published var messages: [ChatMessage] = []
    @Published var status = ""
    /// Whether the last status is a failure (drives its colour).
    @Published var statusIsError = false
    @Published var busy = false
    @Published var username: String

    private var backend: Backend

    /// The `Mero` admin calls use: the relay's Bearer session, or the node.
    private var mero: Mero? {
        switch backend {
        case .relay(let connection, _): return connection.mero
        case .node(let mero): return mero
        }
    }

    var isRelay: Bool {
        if case .relay = backend { return true }
        return false
    }

    init(backend: Backend, username: String) {
        self.backend = backend
        self.username = username.isEmpty ? "dev" : username
        // A relay needs no install: the application is the namespace's own.
        if case .relay = backend { appId = "relay" }
    }

    // MARK: setup / install (node backend)

    func setup() async {
        guard case .node(let mero) = backend else { return }
        await run("Installing \(Self.packageName)…") {
            let versions = try await mero.admin.getRegistryVersions(
                registryUrl: Self.registryURL, packageName: Self.packageName)
            guard let version = versions.first else { self.say("No registry versions found", error: true); return }
            let resp = try await mero.admin.installFromRegistry(packageName: Self.packageName, version: version)
            self.appId = resp.applicationId
            self.say("Installed \(Self.packageName)@\(version)")
            await self.loadSpaces()
        }
    }

    /// Adopt curb's app id if it is already installed on the node.
    func detectInstalled() async {
        guard appId == nil, case .node(let mero) = backend else { return }
        if let apps = try? await mero.admin.listApplications(),
            let curb = apps.apps.first(where: { $0.package == Self.packageName })
        {
            appId = curb.id
            await loadSpaces()
        }
    }

    /// Live events for a channel's context, or an empty stream when reads are off.
    func eventStream(_ channel: ChatChannel) -> AsyncThrowingStream<ContextEvent, Error> {
        guard let mero else { return AsyncThrowingStream { $0.finish() } }
        return mero.events(contextIds: [channel.contextId])
    }

    // MARK: spaces

    func loadSpaces() async {
        guard let mero else {
            say("Reads are off until the relay session is established. Writes still work.", error: true)
            return
        }
        do {
            let all = try await mero.admin.listNamespaces()
            spaces = all.map {
                ChatSpace(id: $0.namespaceId, name: $0.name ?? "Space", applicationId: $0.targetApplicationId)
            }
        } catch { say("Couldn't load spaces: \(short(error))", error: true) }
    }

    /// A node creates spaces; a Cloud account founds them through its relay.
    var canCreateSpaces: Bool {
        switch backend {
        case .relay(let connection, _): return connection.relay != nil
        case .node: return true
        }
    }

    func createSpace(_ name: String) async {
        switch backend {
        case .relay(let connection, let signIn):
            await run("Creating space \(name)…") {
                // Founds the namespace as the account: curb from the registry,
                // mero-react's default capabilities, the name, then HA.
                let founded = try await signIn.foundNamespace(connection, name: name, package: Self.packageName)
                self.say(
                    founded.haEnabled
                        ? "Space created: \(founded.namespaceId.prefix(8))"
                        : "Space created: \(founded.namespaceId.prefix(8)). Not hosted in the cloud yet: "
                            + (founded.haError ?? "unknown reason"),
                    error: false)
                await self.loadSpaces()
            }
        case .node(let mero):
            guard let appId else { return }
            await run("Creating space \(name)…") {
                let resp = try await mero.admin.createNamespace(
                    CreateNamespaceRequest(applicationId: appId, name: name))
                self.say("Space created: \(resp.namespaceId.prefix(8))")
                await self.loadSpaces()
            }
        }
    }

    // MARK: channels

    func loadChannels(_ space: ChatSpace) async {
        guard let mero else { return }
        channels = []
        var out: [ChatChannel] = []
        do {
            let subgroups = try await mero.admin.listNamespaceGroups(space.id)
            for sg in subgroups {
                let ctxs = try await mero.admin.listGroupContexts(sg.groupId)
                guard let ctx = ctxs.first else { continue }
                if let channel = await channel(
                    contextId: ctx.contextId, groupId: sg.groupId, fallback: sg.name ?? ctx.name)
                {
                    out.append(channel)
                }
            }
        } catch  where isRelay {
            // An account session lists its own contexts; take the ones in this space.
            let contexts = (try? await mero.admin.getContexts().contexts) ?? []
            for ctx in contexts
            where ctx.groupId == nil || ctx.groupId == space.id || ctx.applicationId == space.applicationId {
                if let channel = await channel(contextId: ctx.id, groupId: ctx.groupId ?? space.id, fallback: nil) {
                    out.append(channel)
                }
            }
        } catch {
            say("Couldn't load channels: \(short(error))", error: true)
        }
        channels = out.filter { $0.kind != "Dm" }
        if channels.isEmpty, !isRelay { await diagnoseEmptySpace(space) }
    }

    private func channel(contextId: String, groupId: String, fallback: String?) async -> ChatChannel? {
        var executor = ""
        if case .node(let mero) = backend {
            executor = (try? await mero.admin.getContextIdentitiesOwned(contextId))?.identities.first ?? ""
            if executor.isEmpty {
                _ = try? await mero.admin.joinContext(contextId)
                _ = try? await mero.admin.syncContext(contextId)
                executor = (try? await mero.admin.getContextIdentitiesOwned(contextId))?.identities.first ?? ""
            }
        }
        var name = fallback ?? "channel"
        var kind = "Channel"
        let info: ChatContextInfo? = try? await read(contextId, "get_info", executor: executor)
        if let info {
            name = info.name
            kind = info.contextType
        }
        return ChatChannel(
            id: contextId, groupId: groupId, contextId: contextId, executorId: executor, name: name, kind: kind)
    }

    /// Why a joined space shows no channels (node backend).
    private func diagnoseEmptySpace(_ space: ChatSpace) async {
        guard case .node(let mero) = backend else { return }
        let peers = (try? await mero.admin.getPeersCount())?.count
        if peers == 0 {
            say("Joined, but this node has no peers, so it can't sync the channel from the inviter.", error: true)
        } else {
            say("No channels yet. They may still be syncing; pull to refresh.")
        }
    }

    func createChannel(in space: ChatSpace, name: String, open: Bool) async {
        switch backend {
        case .relay(let connection, _):
            guard let relay = connection.relay else { return say("No relay serves this account yet.", error: true) }
            await run("Creating #\(name)…") {
                let created = try await relay.createContext(
                    groupId: space.id, applicationId: space.applicationId, initArgs: self.initArgs(name: name),
                    name: name)
                _ = try? await relay.execute(
                    contextId: created.contextId, method: "set_profile",
                    argsJson: ["username": .string(self.username), "avatar": .null])
                self.say("Channel #\(name) created")
                await self.loadChannels(space)
            }
        case .node(let mero):
            guard let appId else { return say("Install the app first.", error: true) }
            await run("Creating #\(name)…") {
                let sg = try await mero.admin.createGroupInNamespace(
                    space.id, request: CreateGroupInNamespaceRequest(groupName: name))
                try await mero.admin.setSubgroupVisibility(
                    sg.groupId,
                    request: SetSubgroupVisibilityRequest(subgroupVisibility: open ? "open" : "restricted"))
                let bytes = (try? JSONSerialization.data(withJSONObject: self.initObject(name: name))) ?? Data()
                let ctx = try await mero.admin.createContext(
                    CreateContextRequest(
                        applicationId: appId, groupId: sg.groupId, initializationParams: bytes.map { Int($0) },
                        name: name))
                let _: String? = try? await self.write(
                    ctx.contextId, "set_profile", executor: ctx.memberPublicKey,
                    args: ["username": .string(self.username), "avatar": .null])
                self.say("Channel #\(name) created")
                await self.loadChannels(space)
            }
        }
    }

    // MARK: messages

    func loadMessages(_ channel: ChatChannel) async {
        guard isRelay || !channel.executorId.isEmpty else { return }
        do {
            let page: ChatMessagePage = try await read(
                channel.contextId, "get_messages", executor: channel.executorId,
                args: ["parent_message": .null, "limit": .number(50), "offset": .number(0), "search_term": .null])
            messages = page.messages.filter { $0.deleted != true }
        } catch { say("Couldn't load messages: \(short(error))", error: true) }
    }

    func sendMessage(_ channel: ChatChannel, _ text: String) async {
        guard !text.isEmpty, isRelay || !channel.executorId.isEmpty else { return }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        do {
            let _: ChatMessage = try await write(
                channel.contextId, "send_message", executor: channel.executorId,
                args: [
                    "message": .string(text),
                    "mentions": .array([]),
                    "mentions_usernames": .array([]),
                    "parent_message": .null,
                    "timestamp": .number(Double(ts)),
                    "sender_username": .string(username),
                    "files": .null,
                    "images": .null,
                ])
            await loadMessages(channel)
        } catch { say("Couldn't send: \(short(error))", error: true) }
    }

    // MARK: invite / join

    /// Both backends invite: a node signs with its namespace key, an account
    /// with its device key (needs the relay session to read the members).
    var canInvite: Bool {
        switch backend {
        case .relay(let connection, _): return connection.mero != nil
        case .node: return true
        }
    }

    func makeInvite(_ space: ChatSpace) async -> String? {
        do {
            let signed: SignedGroupOpenInvitation
            switch backend {
            case .relay(let connection, let signIn):
                signed = try await signIn.createNamespaceInvitation(connection, namespaceId: space.id)
            case .node(let mero):
                let result = try await mero.admin.createNamespaceInvitation(space.id)
                switch result {
                case .single(let data):
                    signed = data.invitation
                case .recursive(let data):
                    guard let first = data.invitations.first else {
                        say("The node returned no invitations.", error: true)
                        return nil
                    }
                    signed = first.invitation
                }
            }
            let code = try ChatInvite(namespaceId: space.id, spaceName: space.name, invitation: signed).encoded()
            print("[MeroKit] invite code for \(space.name):\n\(code)")
            say("Invite ready. Copy or share it.")
            return code
        } catch {
            say("Couldn't create an invite: \(short(error))", error: true)
            return nil
        }
    }

    /// Join a space from an invite code. Returns whether it joined.
    @discardableResult
    func joinSpace(_ inviteCode: String) async -> Bool {
        busy = true
        defer { busy = false }
        say("Reading invite…")
        guard let invite = ChatInvite.decode(inviteCode) else {
            say("That isn't a valid invite code.", error: true)
            return false
        }
        switch backend {
        case .relay(_, let signIn):
            do {
                say("Joining \(invite.spaceName)…")
                let (_, outcome) = try await signIn.join(namespaceId: invite.namespaceId, invitation: invite.invitation)
                say(
                    outcome.published
                        ? "Joined \(invite.spaceName). Channels appear as the relay syncs."
                        : "The join was sent, but not yet published. Try again shortly.",
                    error: !outcome.published)
                await loadSpaces()
                return outcome.published
            } catch {
                say("Couldn't join: \(short(error))", error: true)
                return false
            }
        case .node(let mero):
            return await joinOnNode(mero, invite)
        }
    }

    private func joinOnNode(_ mero: Mero, _ invite: ChatInvite) async -> Bool {
        do {
            say("Joining \(invite.spaceName)…")
            let joined = try await mero.admin.joinNamespace(
                invite.namespaceId,
                request: JoinNamespaceRequest(invitation: invite.invitation, groupName: invite.spaceName))
            var synced = false
            for attempt in 1...6 {
                say("Syncing \(invite.spaceName) from the inviter (\(attempt)/6)…")
                let contexts = (try? await mero.admin.syncGroupContexts(joined.namespaceId)) ?? []
                for ctx in contexts {
                    let owned = try? await mero.admin.getContextIdentitiesOwned(ctx.contextId)
                    if let executor = owned?.identities.first {
                        let _: String? = try? await write(
                            ctx.contextId, "set_profile", executor: executor,
                            args: ["username": .string(username), "avatar": .null])
                    }
                }
                await loadSpaces()
                if let space = spaces.first(where: { $0.id == invite.namespaceId }) {
                    await loadChannels(space)
                    if !channels.isEmpty { synced = true; break }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await loadSpaces()
            say(
                synced
                    ? "Joined \(invite.spaceName): \(channels.count) channel(s)"
                    : "Joined \(invite.spaceName). Channels are still syncing; pull to refresh.")
            return true
        } catch {
            say("Couldn't join: \(short(error))", error: true)
            return false
        }
    }

    /// Re-sync a space's channels.
    func resync(_ space: ChatSpace) async {
        await run("Syncing \(space.name)…") {
            if case .node(let mero) = self.backend { _ = try? await mero.admin.syncGroupContexts(space.id) }
            await self.loadChannels(space)
            self.say(self.channels.isEmpty ? "No channels yet." : "\(self.channels.count) channel(s)")
        }
    }

    // MARK: helpers

    private func initObject(name: String) -> [String: Any] {
        [
            "name": name, "context_type": "Channel", "description": "",
            "created_at": Int(Date().timeIntervalSince1970), "creator_username": username,
        ]
    }

    private func initArgs(name: String) -> JSONValue {
        [
            "name": .string(name), "context_type": "Channel", "description": "",
            "created_at": .number(Double(Int(Date().timeIntervalSince1970))),
            "creator_username": .string(username),
        ]
    }

    /// A read: the relay's query (warrant fallback), or JSON-RPC on a node.
    private func read<T: Decodable>(
        _ contextId: String, _ method: String, executor: String, args: [String: JSONValue] = [:]
    ) async throws -> T {
        switch backend {
        case .relay(let connection, _):
            guard let relay = connection.relay else { throw AccountError.notSignedIn("no relay") }
            return try await relay.query(T.self, contextId: contextId, method: method, argsJson: .object(args))
        case .node(let mero):
            return try await mero.rpc.execute(contextId: contextId, method: method, argsJson: args)
        }
    }

    /// A write: a warrant through the relay, or JSON-RPC on a node.
    private func write<T: Decodable>(
        _ contextId: String, _ method: String, executor: String, args: [String: JSONValue] = [:]
    ) async throws -> T {
        switch backend {
        case .relay(let connection, _):
            guard let relay = connection.relay else { throw AccountError.notSignedIn("no relay") }
            return try await relay.execute(T.self, contextId: contextId, method: method, argsJson: .object(args))
        case .node(let mero):
            return try await mero.rpc.execute(contextId: contextId, method: method, argsJson: args)
        }
    }

    private func say(_ message: String, error: Bool = false) {
        status = message
        statusIsError = error
    }

    private func run(_ message: String, _ body: @escaping () async throws -> Void) async {
        busy = true
        say(message)
        defer { busy = false }
        do { try await body() } catch {
            say("\(message.replacingOccurrences(of: "…", with: "")) failed: \(short(error))", error: true)
        }
    }

    private func short(_ error: Error) -> String {
        if let u = error as? URLError { return "network \(u.code)" }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
