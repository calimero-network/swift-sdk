import Foundation
import MeroKit

// In-memory stand-ins for an app's delegated session, so an app's view models
// are unit-testable with no relay, no cloud and no wallet. (== Kotlin
// mero-testkit `InMemoryAppBackend` / `RecordingContextContract`.)

/// One contract call a ``RecordingContextContract`` saw.
public struct RecordedContractCall: Equatable, Sendable {
    public enum Path: String, Sendable {
        case query
        case execute
    }

    public let path: Path
    public let contextId: String
    public let method: String
    public let args: JSONValue

    public init(path: Path, contextId: String, method: String, args: JSONValue) {
        self.path = path
        self.contextId = contextId
        self.method = method
        self.args = args
    }
}

/// A ``ContextContract`` that records every call and answers from a handler
/// (`null` by default). Script the app's contract in the handler, by method.
public final class RecordingContextContract: ContextContract, @unchecked Sendable {
    public typealias Handler = @Sendable (RecordedContractCall) throws -> JSONValue?

    private let lock = NSLock()
    private var recorded: [RecordedContractCall] = []
    private var handler: Handler

    public init(handler: @escaping Handler = { _ in .null }) {
        self.handler = handler
    }

    /// Every call so far, in order.
    public var calls: [RecordedContractCall] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The calls to `method`.
    public func calls(_ method: String) -> [RecordedContractCall] {
        calls.filter { $0.method == method }
    }

    public func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded.removeAll()
    }

    public func query(contextId: String, method: String, args: JSONValue) async throws -> JSONValue? {
        try record(RecordedContractCall(path: .query, contextId: contextId, method: method, args: args))
    }

    public func execute(contextId: String, method: String, args: JSONValue) async throws -> JSONValue? {
        try record(RecordedContractCall(path: .execute, contextId: contextId, method: method, args: args))
    }

    private func record(_ call: RecordedContractCall) throws -> JSONValue? {
        lock.lock()
        recorded.append(call)
        let current = handler
        lock.unlock()
        return try current(call)
    }
}

/// A ``MeroAppBackend`` that keeps its namespaces, subgroups, contexts and
/// memberships in memory, and whose contract is a ``RecordingContextContract``.
///
/// It behaves like the relay as far as a view model can tell: founding adds a
/// namespace, creating a subgroup or a context adds it (the creator is a
/// member of a context it creates), joining a context makes the account a
/// member, and redeeming an invitation adds the namespace and gives a
/// relayless account its relay. Seed state with the `namespaces`, `subgroups`
/// and `members` properties; make every admin-side call fail with ``failure``;
/// push live events with ``emit(_:)``. ``log`` lists what was asked, in order.
public final class InMemoryAppBackend: MeroAppBackend, @unchecked Sendable {
    public let account: String
    public let recording: RecordingContextContract

    private let lock = NSLock()
    private var state = State()

    private struct State {
        var hasRelay = true
        var canSubscribe = true
        var applicationId = String(repeating: "ap", count: 32)
        var failure: Error?
        var haEnabled = true
        var joinRelayURL = "https://relay.test"
        var namespaces: [AppNamespace] = []
        var subgroups: [String: [AppSubgroup]] = [:]
        var rootContexts: [String: [String]] = [:]
        var members: Set<String> = []
        var publicSubgroups: Set<String> = []
        var initArgs: [String: JSONValue] = [:]
        var log: [String] = []
        var next = 0
        var streams: [UUID: (contextId: String, continuation: AsyncThrowingStream<AppContextEvent, Error>.Continuation)] =
            [:]
    }

    public init(
        account: String = String(repeating: "ab", count: 32),
        contract: RecordingContextContract = RecordingContextContract()
    ) {
        self.account = account
        self.recording = contract
    }

    // MARK: Scripted state

    /// The contract: ``recording``, or ``NoRelayContextContract`` while ``hasRelay`` is false.
    public var contract: any ContextContract { hasRelay ? recording : NoRelayContextContract() }
    public var hasRelay: Bool {
        get { read { $0.hasRelay } }
        set { write { $0.hasRelay = newValue } }
    }
    public var canSubscribe: Bool {
        get { read { $0.canSubscribe } }
        set { write { $0.canSubscribe = newValue } }
    }
    /// The application a founded or joined namespace runs.
    public var applicationId: String {
        get { read { $0.applicationId } }
        set { write { $0.applicationId = newValue } }
    }
    /// Thrown by every call but ``events(contextId:)`` and the contract while set.
    public var failure: Error? {
        get { read { $0.failure } }
        set { write { $0.failure = newValue } }
    }
    /// What ``foundNamespace(name:)`` reports about hosting.
    public var haEnabled: Bool {
        get { read { $0.haEnabled } }
        set { write { $0.haEnabled = newValue } }
    }
    /// The relay ``joinNamespace(namespaceId:invitation:)`` reports.
    public var joinRelayURL: String {
        get { read { $0.joinRelayURL } }
        set { write { $0.joinRelayURL = newValue } }
    }
    public var namespaces: [AppNamespace] {
        get { read { $0.namespaces } }
        set { write { $0.namespaces = newValue } }
    }
    /// Subgroups by namespace id.
    public var subgroups: [String: [AppSubgroup]] {
        get { read { $0.subgroups } }
        set { write { $0.subgroups = newValue } }
    }
    /// Contexts directly in a group that is not a listed subgroup (a namespace's root), by group id.
    public var rootContexts: [String: [String]] {
        get { read { $0.rootContexts } }
        set { write { $0.rootContexts = newValue } }
    }
    /// The contexts the account is a member of.
    public var members: Set<String> {
        get { read { $0.members } }
        set { write { $0.members = newValue } }
    }
    /// The subgroups created open.
    public var publicSubgroups: Set<String> { read { $0.publicSubgroups } }
    /// The `initArgs` each created context was given, by context id.
    public var initArgs: [String: JSONValue] { read { $0.initArgs } }
    /// What was asked, in order: `"foundNamespace Team"`, `"joinContext <id>"`, ...
    public var log: [String] { read { $0.log } }

    // MARK: MeroAppBackend

    public func listNamespaces() async throws -> [AppNamespace] {
        try step("listNamespaces") { $0.namespaces }
    }

    public func listSubgroups(namespaceId: String) async throws -> [AppSubgroup] {
        try step("listSubgroups \(namespaceId)") { $0.subgroups[namespaceId] ?? [] }
    }

    public func listContexts(groupId: String) async throws -> [String] {
        try step("listContexts \(groupId)") { state in
            for list in state.subgroups.values {
                if let found = list.first(where: { $0.groupId == groupId }) { return found.contextIds }
            }
            return state.rootContexts[groupId] ?? []
        }
    }

    public func isMember(contextId: String) async throws -> Bool {
        try step("isMember \(contextId)") { $0.members.contains(contextId) }
    }

    public func joinContext(contextId: String) async throws {
        try step("joinContext \(contextId)") { _ = $0.members.insert(contextId) }
    }

    public func foundNamespace(name: String) async throws -> AppFoundedNamespace {
        try step("foundNamespace \(name)") { state in
            guard state.hasRelay else { throw AccountError.noRelay(method: "foundNamespace") }
            let id = Self.mint("aa", &state.next)
            state.namespaces.append(AppNamespace(id: id, name: name, applicationId: state.applicationId, memberCount: 1))
            return AppFoundedNamespace(
                namespaceId: id, haEnabled: state.haEnabled, haError: state.haEnabled ? nil : "not hosted (fake)")
        }
    }

    public func createSubgroup(namespaceId: String, name: String, isPublic: Bool) async throws -> String {
        try step("createSubgroup \(namespaceId) \(name) \(isPublic ? "open" : "restricted")") { state in
            let id = Self.mint("bb", &state.next)
            state.subgroups[namespaceId, default: []].append(AppSubgroup(groupId: id, name: name, contextIds: []))
            if isPublic { state.publicSubgroups.insert(id) }
            return id
        }
    }

    public func createContext(
        groupId: String, applicationId: String, name: String, initArgs: JSONValue
    ) async throws -> String {
        try step("createContext \(groupId) \(applicationId) \(name)") { state in
            let id = Self.mint("cc", &state.next)
            var placed = false
            for (namespace, list) in state.subgroups {
                guard let index = list.firstIndex(where: { $0.groupId == groupId }) else { continue }
                let old = list[index]
                state.subgroups[namespace]?[index] = AppSubgroup(
                    groupId: old.groupId, name: old.name, contextIds: old.contextIds + [id])
                placed = true
            }
            if !placed { state.rootContexts[groupId, default: []].append(id) }
            state.members.insert(id)
            state.initArgs[id] = initArgs
            return id
        }
    }

    public func createInvitation(namespaceId: String) async throws -> SignedGroupOpenInvitation {
        try step("createInvitation \(namespaceId)") { _ in Self.invitation(namespaceId: namespaceId) }
    }

    public func joinNamespace(
        namespaceId: String, invitation: SignedGroupOpenInvitation
    ) async throws -> AppJoinedNamespace {
        try step("joinNamespace \(namespaceId)") { state in
            if !state.namespaces.contains(where: { $0.id == namespaceId }) {
                state.namespaces.append(AppNamespace(id: namespaceId, name: nil, applicationId: state.applicationId))
            }
            state.hasRelay = true
            return AppJoinedNamespace(namespaceId: namespaceId, published: true, relayURL: state.joinRelayURL)
        }
    }

    public func events(contextId: String) -> AsyncThrowingStream<AppContextEvent, Error> {
        guard canSubscribe else { return AsyncThrowingStream { $0.finish() } }
        let id = UUID()
        return AsyncThrowingStream { continuation in
            write { $0.streams[id] = (contextId, continuation) }
            continuation.onTermination = { [weak self] _ in self?.write { $0.streams[id] = nil } }
        }
    }

    // MARK: Driving it

    /// Deliver `event` to every open ``events(contextId:)`` stream for its context.
    public func emit(_ event: AppContextEvent) {
        let targets = read { $0.streams.values.filter { $0.contextId == event.contextId }.map(\.continuation) }
        for continuation in targets { continuation.yield(event) }
    }

    /// Finish every open event stream, with `error` when given.
    public func finishEvents(throwing error: Error? = nil) {
        let targets = read { $0.streams.values.map(\.continuation) }
        for continuation in targets { continuation.finish(throwing: error) }
    }

    /// An invitation to `namespaceId` shaped like a real one (its signature is not).
    public static func invitation(namespaceId: String) -> SignedGroupOpenInvitation {
        let group = (try? Hex.decode(namespaceId, label: "namespaceId", bytes: 32)).map { $0.map(Int.init) }
        return SignedGroupOpenInvitation(
            invitation: GroupInvitationFromAdmin(
                inviterIdentity: Array(repeating: 1, count: 32), groupId: group ?? Array(repeating: 0, count: 32),
                expirationTimestamp: 4_102_444_800, secretSalt: Array(repeating: 2, count: 32)),
            inviterSignature: String(repeating: "00", count: 64))
    }

    // MARK: Plumbing

    private static func mint(_ prefix: String, _ next: inout Int) -> String {
        next += 1
        let digits = String(next, radix: 16)
        return prefix + String(repeating: "0", count: 64 - prefix.count - digits.count) + digits
    }

    private func step<T>(_ entry: String, _ body: (inout State) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        state.log.append(entry)
        if let failure = state.failure { throw failure }
        return try body(&state)
    }

    private func read<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func write(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&state)
    }
}
