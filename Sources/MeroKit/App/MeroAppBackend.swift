import Foundation

/// Everything an app's screens need from a signed-in Calimero account, and
/// nothing a node would offer: the phone holds no node. The account's relay
/// reads, writes, creates and admits on its behalf.
/// (== Kotlin `com.calimero.mero.app.MeroAppBackend`.)
///
/// The words are the protocol's: a *namespace* is what an app calls a
/// workspace, team or space; a *subgroup* is a group under it (a channel's, a
/// board's); a *context* runs the app's contract in a group.
///
/// `MeroKitUI`'s `DelegatedAppBackend` is the real one, and `MeroAppSession`
/// builds it from the signed-in client. View models take this protocol, so a
/// test hands them `MeroKitTestSupport`'s `InMemoryAppBackend` instead.
public protocol MeroAppBackend: Sendable {
    /// The account, 64 hex.
    var account: String { get }
    /// The contract in any context: relay query for reads, warrants for writes.
    /// ``NoRelayContextContract`` while no relay serves the account.
    var contract: any ContextContract { get }
    /// Whether a relay serves this account. Without one only joining works.
    var hasRelay: Bool { get }
    /// Whether ``events(contextId:)`` streams (the relay's Bearer session is
    /// up). When not, poll.
    var canSubscribe: Bool { get }

    /// The namespaces this account is in, for this app's application only
    /// when the session knows it (an account is used across apps).
    func listNamespaces() async throws -> [AppNamespace]
    /// The subgroups of a namespace and the contexts in each.
    func listSubgroups(namespaceId: String) async throws -> [AppSubgroup]
    /// The contexts directly in `groupId` (a namespace's root group, or a subgroup).
    func listContexts(groupId: String) async throws -> [String]
    /// Whether the account is a member of the context's group, so its contract calls work.
    func isMember(contextId: String) async throws -> Bool
    /// Join a context in an open subgroup: `MemberJoinedOpen` on its group, through the relay.
    func joinContext(contextId: String) async throws

    /// Found a namespace running this app through the relay, named `name`.
    func foundNamespace(name: String) async throws -> AppFoundedNamespace
    /// Create a subgroup under `namespaceId`, open (anyone in the namespace may
    /// join) or restricted. Returns its group id.
    func createSubgroup(namespaceId: String, name: String, isPublic: Bool) async throws -> String
    /// Create a context running `applicationId` in `groupId`, initialised with
    /// `initArgs` (the contract's `init` arguments). Returns its context id.
    func createContext(groupId: String, applicationId: String, name: String, initArgs: JSONValue) async throws
        -> String

    /// Mint an invitation to a namespace, signed with the device key.
    func createInvitation(namespaceId: String) async throws -> SignedGroupOpenInvitation
    /// Redeem an invitation: direct admission through an admitting relay. A
    /// relayless account gets that relay; reconnect after (`MeroAppSession.didJoinNamespace()`).
    func joinNamespace(namespaceId: String, invitation: SignedGroupOpenInvitation) async throws -> AppJoinedNamespace

    /// Live events for one context. Finishes at once when ``canSubscribe`` is false.
    func events(contextId: String) -> AsyncThrowingStream<AppContextEvent, Error>
}

/// A namespace this account is a member of. (== Kotlin `AppNamespace`.)
public struct AppNamespace: Identifiable, Hashable, Sendable {
    /// The namespace id, 64 hex.
    public let id: String
    /// Its name, when it has one.
    public let name: String?
    /// The application it runs: what a new context in it is created with.
    public let applicationId: String
    public let memberCount: Int

    public init(id: String, name: String?, applicationId: String, memberCount: Int = 0) {
        self.id = id
        self.name = name
        self.applicationId = applicationId
        self.memberCount = memberCount
    }
}

/// A subgroup of a namespace, and the contexts in it. (== Kotlin `AppSubgroup`.)
public struct AppSubgroup: Hashable, Sendable {
    public let groupId: String
    public let name: String?
    public let contextIds: [String]

    public init(groupId: String, name: String?, contextIds: [String]) {
        self.groupId = groupId
        self.name = name
        self.contextIds = contextIds
    }
}

/// What founding a namespace came to. (== Kotlin `AppFoundedNamespace`.)
public struct AppFoundedNamespace: Hashable, Sendable {
    public let namespaceId: String
    /// Whether the cloud agreed to host the namespace. Invitees find it only then.
    public let haEnabled: Bool
    /// Why `haEnabled` is false, in words a person can act on.
    public let haError: String?
    /// Why the name could not be set, when the namespace exists anyway. Always
    /// `nil` here: this SDK throws when naming fails.
    public let nameError: String?

    public init(namespaceId: String, haEnabled: Bool, haError: String? = nil, nameError: String? = nil) {
        self.namespaceId = namespaceId
        self.haEnabled = haEnabled
        self.haError = haError
        self.nameError = nameError
    }
}

/// What redeeming an invitation came to. (== Kotlin `AppJoinedNamespace`.)
public struct AppJoinedNamespace: Hashable, Sendable {
    public let namespaceId: String
    /// NOT "joined": membership lands once peers apply the op.
    public let published: Bool
    /// The relay that admitted the account.
    public let relayURL: String

    public init(namespaceId: String, published: Bool, relayURL: String) {
        self.namespaceId = namespaceId
        self.published = published
        self.relayURL = relayURL
    }
}

/// A live event in a context: something changed there. (== Kotlin `AppContextEvent`.)
public struct AppContextEvent: Hashable, Sendable {
    public let contextId: String
    /// The node's event kind, e.g. `StateMutation`, `ExecutionEvent`, `Ephemeral`.
    public let kind: String

    public init(contextId: String, kind: String) {
        self.contextId = contextId
        self.kind = kind
    }
}
