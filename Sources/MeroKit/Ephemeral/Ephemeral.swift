import Foundation

/// Encoding for a presence slice. The node never deserializes it: the wire
/// encoding is chosen client-side and travels client to client, as the
/// `state: [UInt8]` byte array. (== mero-js `Codec<T>`.)
public protocol Codec: Sendable {
    associatedtype Value
    func encode(_ value: Value) throws -> [UInt8]
    func decode(_ bytes: [UInt8]) throws -> Value
}

/// The default codec: JSON text as bytes. (== mero-js `jsonCodec()`.)
public struct JSONCodec<Value: Codable>: Codec {
    public init() {}

    public func encode(_ value: Value) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return Array(try encoder.encode(value))
    }

    public func decode(_ bytes: [UInt8]) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(bytes))
    }
}

/// One presence entry from a subscription. (== mero-js `EphemeralEntry<T>`.)
///
/// On subscribing to a context, the node replays that context's current
/// presence as ordinary `Ephemeral` events before any live delta. ``ageMs``
/// tells them apart: it is `nil` on a live delta (fresh at receipt) and set on
/// a replayed entry — milliseconds since that author was last heard from,
/// measured on the node, bounded by the node's 7 s presence TTL.
public struct EphemeralEntry<State> {
    /// The signing key of the peer whose slot this is.
    public let author: String
    /// The account a relay-carried update's device certificate names, hex.
    /// `nil` for a node's own presence.
    public let account: String?
    /// The decoded slice; `nil` on a removal.
    public let state: State?
    /// The author's slot was removed (went offline).
    public let removed: Bool
    /// Set only on a replayed entry. Never synthesized as `0`.
    public let ageMs: UInt64?

    public init(author: String, account: String? = nil, state: State?, removed: Bool, ageMs: UInt64? = nil) {
        self.author = author
        self.account = account
        self.state = state
        self.removed = removed
        self.ageMs = ageMs
    }
}

extension EphemeralEntry: Sendable where State: Sendable {}
extension EphemeralEntry: Equatable where State: Equatable {}

extension EphemeralEntry where State: Sendable {
    /// The entry an `Ephemeral` event's data object describes, or `nil` when
    /// it names no author or its state does not decode with `codec`.
    static func decode<C: Codec>(_ data: JSONValue, codec: C) -> EphemeralEntry<State>? where C.Value == State {
        guard case .string(let author)? = data["author"], !author.isEmpty else { return nil }
        // `removed` is omitted on an upsert: read it as a boolean here.
        let removed = SseConnection.truthy(data["removed"])
        var state: State?
        if !removed, case .array(let items)? = data["state"] {
            var bytes = [UInt8]()
            bytes.reserveCapacity(items.count)
            for item in items {
                guard case .number(let n) = item, n >= 0, n <= 255, n == n.rounded() else { return nil }
                bytes.append(UInt8(n))
            }
            guard let decoded = try? codec.decode(bytes) else { return nil }
            state = decoded
        }
        let ageMs = data["ageMs"]?.doubleValue.map { UInt64(max(0, $0)) }
        return EphemeralEntry(
            author: author, account: data["account"]?.stringValue, state: state, removed: removed, ageMs: ageMs)
    }
}

/// Ephemeral presence: transient, encrypted, never-persisted state (cursors,
/// typing, presence) that gossips between nodes without a WASM run or DAG
/// growth. Port of mero-js `EphemeralClient`; reach it as ``Mero/ephemeral``.
///
/// The write/read asymmetry is the model. ``set(contextId:state:codec:)``
/// takes no author: you only ever write your OWN slot, and the node resolves
/// the author from its owned context identity. ``subscribe(contextId:codec:)``
/// returns everyone's slots, each with its `author`.
///
/// There is a single read path: the subscription. The node replays a context's
/// current presence when it is first subscribed on a connection; the
/// connection keeps it (``SseConnection/presenceSeed(_:)``) and replays it to
/// every later subscriber of the same context.
public struct EphemeralClient: Sendable {
    private let rpc: RpcClient
    /// The event connection presence is read from.
    public let events: SseConnection

    public init(rpc: RpcClient, events: SseConnection) {
        self.rpc = rpc
        self.events = events
    }

    /// Publish your own presence slice, replacing it wholesale
    /// (JSON-RPC `set_ephemeral` with `{contextId, state: [UInt8]}`).
    ///
    /// Throws ``MeroError/rpc(_:)`` with the node's `type` and `data` — e.g.
    /// `SliceTooLarge` past 16 384 bytes, `Unauthorized` for a non-member.
    public func set<C: Codec>(contextId: String, state: C.Value, codec: C) async throws {
        _ = try await rpc.call(
            "set_ephemeral", params: SetEphemeralParams(contextId: contextId, state: codec.encode(state)))
    }

    /// ``set(contextId:state:codec:)`` with the JSON codec.
    public func set<T: Codable>(contextId: String, state: T) async throws {
        try await set(contextId: contextId, state: state, codec: JSONCodec<T>())
    }

    /// Presence changes for `contextId`: the kept presence first (when this
    /// connection already holds the context), then the node's replay and live
    /// deltas. Connects and subscribes the context as needed; errors of that
    /// surface on ``SseConnection/updates()``. The stream ends when the
    /// connection closes. (== mero-js `subscribe` / `subscribePresence`.)
    public func subscribe<C: Codec>(
        contextId: String, codec: C
    ) -> AsyncThrowingStream<EphemeralEntry<C.Value>, Error> where C.Value: Sendable {
        presenceStream(events, contextId: contextId, codec: codec)
    }

    /// ``subscribe(contextId:codec:)`` with the JSON codec.
    public func subscribe<T: Codable & Sendable>(
        contextId: String, as type: T.Type = T.self
    ) -> AsyncThrowingStream<EphemeralEntry<T>, Error> {
        subscribe(contextId: contextId, codec: JSONCodec<T>())
    }
}

struct SetEphemeralParams: Encodable, Sendable {
    let contextId: String
    let state: [UInt8]
}

/// Presence for one context off an event connection: a typed filter over its
/// `Ephemeral` events, seeded with what the connection kept. Shared by a node
/// client and an account's relay client. (== mero-js `subscribePresence`.)
public func presenceStream<C: Codec>(
    _ connection: SseConnection, contextId: String, codec: C
) -> AsyncThrowingStream<EphemeralEntry<C.Value>, Error> where C.Value: Sendable {
    AsyncThrowingStream { continuation in
        let listener = EventListener<SseConnectionEvent>(
            event: { event in
                guard case .event(.context(let context)) = event, context.kind == "Ephemeral",
                    context.contextId == contextId, let data = context.data,
                    let entry = EphemeralEntry<C.Value>.decode(data, codec: codec)
                else { return }
                continuation.yield(entry)
            },
            finish: { error in continuation.finish(throwing: error) })
        let id = connection.addListener(listener, seedPresenceFor: contextId)
        continuation.onTermination = { [weak connection] _ in connection?.removeListener(id) }
        connection.connect()
        Task { _ = try? await connection.subscribe(contextIds: [contextId]) }
    }
}
