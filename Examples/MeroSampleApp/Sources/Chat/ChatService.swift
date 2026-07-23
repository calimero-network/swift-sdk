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
}

struct ChatChannel: Identifiable, Equatable {
    let id: String  // contextId
    let groupId: String
    let contextId: String
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

    /// A compact, single-line invite code — zlib-compressed JSON, base64'd —
    /// so it's easy to copy-paste between simulators (like mero-chat's codes).
    func encoded() throws -> String {
        let json = try JSONEncoder().encode(self)
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        return compressed.base64EncodedString()
    }

    /// Decode an invite code. Tries the compact form first, then falls back to
    /// raw JSON (tolerant of older/hand-pasted invites).
    static func decode(_ code: String) -> ChatInvite? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// A native curb (mero-chat) frontend over the authenticated `Mero` client:
/// install the app, create/list spaces (namespaces), channels (subgroup+context),
/// send/read messages (contract RPC), invite, and join. Same logic as mero-chat,
/// in Swift, on the same WASM contract.
@MainActor
final class ChatService: ObservableObject {
    static let registryURL = "https://apps.calimero.network"
    static let packageName = "com.calimero.curb"

    @Published var appId: String?
    @Published var spaces: [ChatSpace] = []
    @Published var channels: [ChatChannel] = []
    @Published var messages: [ChatMessage] = []
    @Published var status = ""
    @Published var busy = false
    @Published var username: String

    private let mero: Mero

    init(mero: Mero, username: String) {
        self.mero = mero
        self.username = username.isEmpty ? "dev" : username
    }

    // MARK: setup / install

    func setup() async {
        await run("installing \(Self.packageName)…") {
            let versions = try await self.mero.admin.getRegistryVersions(
                registryUrl: Self.registryURL, packageName: Self.packageName)
            guard let version = versions.first else { self.status = "no registry versions found"; return }
            let resp = try await self.mero.admin.installFromRegistry(
                registryUrl: Self.registryURL, packageName: Self.packageName, version: version)
            self.appId = resp.applicationId
            self.status = "installed \(Self.packageName)@\(version)"
            await self.loadSpaces()
        }
    }

    /// If curb is already installed on the node, adopt its app id so we skip the
    /// install gate (fixes re-opening chat asking to install again).
    func detectInstalled() async {
        guard appId == nil else { return }
        if let apps = try? await mero.admin.listApplications(),
            let curb = apps.apps.first(where: { $0.package == Self.packageName })
        {
            appId = curb.id
            status = "\(Self.packageName) already installed"
            await loadSpaces()
        }
    }

    /// Live SSE event stream for a channel's context (new messages, etc.).
    func eventStream(_ channel: ChatChannel) -> AsyncThrowingStream<ContextEvent, Error> {
        mero.events(contextIds: [channel.contextId])
    }

    // MARK: spaces

    func loadSpaces() async {
        do {
            let all = try await mero.admin.listNamespaces()
            let mine = appId == nil ? all : all.filter { $0.targetApplicationId == appId }
            spaces = mine.map { ChatSpace(id: $0.namespaceId, name: $0.name ?? "space") }
        } catch { status = "load spaces failed: \(short(error))" }
    }

    func createSpace(_ name: String) async {
        guard let appId else { status = "install the app first"; return }
        await run("creating space “\(name)”…") {
            let resp = try await self.mero.admin.createNamespace(
                CreateNamespaceRequest(applicationId: appId, upgradePolicy: .automatic, name: name))
            self.status = "space created: \(resp.namespaceId)"
            await self.loadSpaces()
        }
    }

    // MARK: channels

    func loadChannels(_ space: ChatSpace) async {
        do {
            channels = []
            let subgroups = try await mero.admin.listNamespaceGroups(space.id)
            var out: [ChatChannel] = []
            for sg in subgroups {
                let ctxs = try await mero.admin.listGroupContexts(sg.groupId)
                guard let ctx = ctxs.first else { continue }
                let executor = (try? await mero.admin.getContextIdentitiesOwned(ctx.contextId))?.identities.first ?? ""
                var name = sg.name ?? ctx.name ?? "channel"
                var kind = "Channel"
                if !executor.isEmpty,
                    let info: ChatContextInfo = try? await rpc(ctx.contextId, "get_info", executor: executor)
                {
                    name = info.name
                    kind = info.contextType
                }
                if kind == "Dm" { continue }
                out.append(
                    ChatChannel(
                        id: ctx.contextId, groupId: sg.groupId, contextId: ctx.contextId,
                        executorId: executor, name: name, kind: kind))
            }
            channels = out
        } catch { status = "load channels failed: \(short(error))" }
    }

    func createChannel(in space: ChatSpace, name: String, open: Bool) async {
        guard let appId else { status = "install the app first"; return }
        await run("creating channel #\(name)…") {
            let sg = try await self.mero.admin.createGroupInNamespace(
                space.id, request: CreateGroupInNamespaceRequest(name: name))
            try await self.mero.admin.setSubgroupVisibility(
                sg.groupId, request: SetSubgroupVisibilityRequest(subgroupVisibility: open ? "open" : "restricted"))
            let ctx = try await self.mero.admin.createContext(
                CreateContextRequest(
                    applicationId: appId, groupId: sg.groupId,
                    initializationParams: self.initParams(name: name), name: name))
            // Register our display name in the new context.
            let _: String? = try? await self.rpc(
                ctx.contextId, "set_profile", executor: ctx.memberPublicKey,
                args: ["username": .string(self.username), "avatar": .null])
            self.status = "channel #\(name) created"
            await self.loadChannels(space)
        }
    }

    // MARK: messages

    func loadMessages(_ channel: ChatChannel) async {
        guard !channel.executorId.isEmpty else { return }
        do {
            let page: ChatMessagePage = try await rpc(
                channel.contextId, "get_messages", executor: channel.executorId,
                args: ["parent_message": .null, "limit": .number(50), "offset": .number(0), "search_term": .null])
            messages = page.messages.filter { $0.deleted != true }
        } catch { status = "load messages failed: \(short(error))" }
    }

    func sendMessage(_ channel: ChatChannel, _ text: String) async {
        guard !text.isEmpty, !channel.executorId.isEmpty else { return }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        do {
            let _: ChatMessage = try await rpc(
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
        } catch { status = "send failed: \(short(error))" }
    }

    // MARK: invite / join

    func makeInvite(_ space: ChatSpace) async -> String? {
        do {
            let result = try await mero.admin.createNamespaceInvitation(space.id)
            let signed: SignedGroupOpenInvitation
            switch result {
            case .single(let data):
                signed = data.invitation
            case .recursive(let data):
                guard let first = data.invitations.first else {
                    status = "invite: node returned no invitations"
                    return nil
                }
                signed = first.invitation
            }
            let invite = ChatInvite(namespaceId: space.id, spaceName: space.name, invitation: signed)
            let code = try invite.encoded()
            print("[MeroKit] invite code for “\(space.name)”:\n\(code)")  // also grabbable via console
            status = "invite ready — Copy or Share it"
            return code
        } catch {
            status = "invite failed: \(short(error))"
            print("[MeroKit] invite failed: \(String(reflecting: error))")
            return nil
        }
    }

    func joinSpace(_ inviteCode: String) async {
        await run("joining space…") {
            guard let invite = ChatInvite.decode(inviteCode) else {
                self.status = "invalid invite code"
                throw MeroError.decoding("invalid invite code")
            }
            let joined = try await self.mero.admin.joinNamespace(
                invite.namespaceId,
                request: JoinNamespaceRequest(invitation: invite.invitation, groupName: invite.spaceName))
            _ = try? await self.mero.admin.syncGroup(joined.groupId)
            self.status = "joined \(invite.spaceName)"
            await self.loadSpaces()
        }
    }

    // MARK: helpers

    private func initParams(name: String) -> [Int] {
        let obj: [String: Any] = [
            "name": name, "context_type": "Channel", "description": "",
            "created_at": Int(Date().timeIntervalSince1970), "creator_username": username,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return [] }
        return data.map { Int($0) }
    }

    @discardableResult
    private func rpc<T: Decodable>(
        _ contextId: String, _ method: String, executor: String, args: [String: JSONValue] = [:]
    ) async throws -> T {
        try await mero.rpc.execute(contextId: contextId, method: method, argsJson: args, executorPublicKey: executor)
    }

    private func run(_ message: String, _ body: @escaping () async throws -> Void) async {
        busy = true
        status = message
        defer { busy = false }
        do { try await body() } catch {
            status = "\(message.replacingOccurrences(of: "…", with: "")) failed: \(short(error))"
        }
    }

    private func short(_ error: Error) -> String {
        if let u = error as? URLError { return "network \(u.code)" }
        return "\(error)"
    }
}
