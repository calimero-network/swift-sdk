import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// What is kept where, how it moves out of `UserDefaults`, and what a sign-out
/// leaves behind (SEC-09, SEC-10, SEC-11).
final class StorageAndSignOutTests: XCTestCase {
    private let relay = DelegatedFixture.relay
    private let otherRelay = "https://relay2.test"
    private let ns = DelegatedFixture.rep("01")
    private let ctx = DelegatedFixture.rep("03")
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "merokit.storage.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// A store whose writes never land (the Keychain before first unlock).
    private final class RefusingStore<Value: Codable & Sendable>: SecureValueStore, @unchecked Sendable {
        func load() -> Value? { nil }
        func save(_ value: Value) {}
        func clear() {}
    }

    // MARK: - Keychain write failures (SEC-09)

    #if canImport(Security)
    func testAFailedKeychainWriteIsCountedAndReported() {
        let reported = Box<[OSStatus]>([])
        let failures = KeychainWriteFailures(onFailure: { status in reported.mutate { $0.append(status) } })
        failures.record(errSecSuccess)
        XCTAssertEqual(failures.failureCount, 0)
        XCTAssertNil(failures.lastFailure)
        failures.record(errSecInteractionNotAllowed)
        failures.record(errSecDuplicateItem)
        XCTAssertEqual(failures.failureCount, 2)
        XCTAssertEqual(failures.lastFailure, errSecDuplicateItem)
        XCTAssertEqual(reported.value, [errSecInteractionNotAllowed, errSecDuplicateItem])
    }
    #endif

    // MARK: - Moving out of UserDefaults (SEC-10)

    private func legacyState() -> AnyValueStore<DelegatedAccountState> {
        let old = UserDefaultsValueStore<DelegatedAccountState>(defaults: defaults, key: "calimero.delegated.state")
        return AnyValueStore(old)
    }

    func testDelegatedStateMovesFromUserDefaultsIntoTheNewStore() {
        let legacy = DelegatedAccountStore.userDefaults(defaults)
        legacy.rememberRelay(account: "aa", relayURL: relay, namespaceId: ns)
        legacy.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.rep("ab"))

        let primary = AnyValueStore<DelegatedAccountState>.memory()
        let store = DelegatedAccountStore(AnyValueStore(MigratingValueStore(primary: primary, legacy: legacyState())))

        XCTAssertEqual(store.relayMap(account: "aa").namespaces, [ns: relay])
        XCTAssertEqual(store.pinnedRelayNodeKey(relayURL: relay), DelegatedFixture.rep("ab"))
        XCTAssertEqual(primary.load()?.relayMaps["aa"]?.namespaces, [ns: relay], "moved into the new store")
        XCTAssertNil(defaults.data(forKey: "calimero.delegated.state"), "and gone from UserDefaults")
    }

    func testDelegatedStateStaysInUserDefaultsWhileTheNewStoreCannotWrite() {
        let legacy = DelegatedAccountStore.userDefaults(defaults)
        legacy.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.rep("ab"))

        let refusing = AnyValueStore(RefusingStore<DelegatedAccountState>())
        let store = DelegatedAccountStore(AnyValueStore(MigratingValueStore(primary: refusing, legacy: legacyState())))

        XCTAssertEqual(store.pinnedRelayNodeKey(relayURL: relay), DelegatedFixture.rep("ab"))
        store.rememberRelay(account: "aa", relayURL: relay, namespaceId: ns)
        XCTAssertNotNil(defaults.data(forKey: "calimero.delegated.state"), "nothing is lost when the move fails")
    }

    func testNoncesMoveFromUserDefaultsWithoutGoingBackwards() {
        let legacy = UserDefaultsWarrantNonceStore(defaults: defaults)
        for _ in 0..<41 { _ = legacy.next(relay: relay) }
        _ = legacy.next(relay: otherRelay)

        let item = AnyValueStore<[String: String]>.memory()
        let nonces = StoredWarrantNonceStore(item, migratingFrom: defaults)
        XCTAssertEqual(nonces.next(relay: relay + "/"), 42)
        XCTAssertEqual(nonces.next(relay: otherRelay), 2, "every relay moved, not only the one asked for")
        XCTAssertEqual(item.load(), [relay: "42", otherRelay: "2"])
        XCTAssertNil(defaults.string(forKey: "calimero.nonce." + relay), "gone from UserDefaults")
        XCTAssertNil(defaults.string(forKey: "calimero.nonce." + otherRelay))
    }

    func testNoncesStayMonotonicAndInUserDefaultsWhileTheStoreCannotWrite() {
        let legacy = UserDefaultsWarrantNonceStore(defaults: defaults)
        for _ in 0..<5 { _ = legacy.next(relay: relay) }

        let nonces = StoredWarrantNonceStore(AnyValueStore(RefusingStore<[String: String]>()), migratingFrom: defaults)
        XCTAssertEqual(nonces.next(relay: relay), 6)
        XCTAssertEqual(nonces.next(relay: relay), 7, "held in memory while the store reads nothing")
        XCTAssertEqual(defaults.string(forKey: "calimero.nonce." + relay), "5", "kept until the move lands")
    }

    func testAStoredNonceSequenceAdvancesAndClears() {
        let item = AnyValueStore<[String: String]>.memory()
        let nonces = StoredWarrantNonceStore(item)
        XCTAssertEqual(nonces.next(relay: relay), 1)
        nonces.advance(relay: relay, to: 10)
        XCTAssertEqual(nonces.next(relay: relay), 10)
        XCTAssertEqual(StoredWarrantNonceStore(item).next(relay: relay), 11, "persisted")
        nonces.clear()
        XCTAssertNil(item.load())
        XCTAssertEqual(nonces.next(relay: relay), 1)
    }

    func testUserDefaultsAndMemoryNoncesClear() {
        let stored = UserDefaultsWarrantNonceStore(defaults: defaults)
        _ = stored.next(relay: relay)
        defaults.set("keep", forKey: "unrelated")
        stored.clear()
        XCTAssertEqual(stored.next(relay: relay), 1)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")

        let memory = MemoryWarrantNonceStore()
        _ = memory.next(relay: relay)
        memory.clear()
        XCTAssertEqual(memory.next(relay: relay), 1)
    }

    // MARK: - Sign-out (SEC-11)

    func testForgetAccountDropsItsMapGroupsAndPinsOnly() {
        let store = DelegatedAccountStore.memory()
        store.rememberRelay(account: "aa", relayURL: relay, namespaceId: ns, contextId: ctx)
        store.rememberGroupNamespace(account: "aa", groupId: DelegatedFixture.rep("04"), namespaceId: ns)
        store.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.rep("ab"))
        store.pinRelayNodeKey(relayURL: otherRelay, nodeKey: DelegatedFixture.rep("cd"))
        store.pinRelayNodeKey(relayURL: "https://unrelated.test", nodeKey: DelegatedFixture.rep("ef"))
        store.rememberRelay(account: "bb", relayURL: otherRelay, namespaceId: ns)

        store.forget(account: "AA", relays: [otherRelay + "/"])

        XCTAssertEqual(store.relayMap(account: "aa"), RelayMap())
        XCTAssertEqual(store.groupNamespaces(account: "aa"), [:])
        XCTAssertNil(store.pinnedRelayNodeKey(relayURL: relay))
        XCTAssertNil(store.pinnedRelayNodeKey(relayURL: otherRelay))
        XCTAssertEqual(store.pinnedRelayNodeKey(relayURL: "https://unrelated.test"), DelegatedFixture.rep("ef"))
        XCTAssertEqual(store.relayMap(account: "bb").namespaces, [ns: otherRelay], "another account's map stays")
    }

    private struct SignedIn {
        let signIn: CloudSignIn
        let keys: AnyValueStore<DeviceKeys>
        let sessions: AnyValueStore<CloudSession>
        let store: DelegatedAccountStore
        let nonces: MemoryWarrantNonceStore
        let account: String
    }

    private func signedIn() -> SignedIn {
        let keys = AnyValueStore<DeviceKeys>.memory(DelegatedFixture.keys)
        let cb = DelegatedFixture.enrolled
        let session = CloudSession(
            account: cb.account, device: DelegatedFixture.keys.signPublicKey, credential: cb.credential,
            relayUrl: relay)
        let sessions = AnyValueStore<CloudSession>.memory(session)
        let store = DelegatedAccountStore.memory()
        store.rememberRelay(account: session.account, relayURL: otherRelay, namespaceId: ns)
        store.rememberGroupNamespace(account: session.account, groupId: DelegatedFixture.rep("04"), namespaceId: ns)
        store.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.rep("ab"))
        store.pinRelayNodeKey(relayURL: otherRelay, nodeKey: DelegatedFixture.rep("cd"))
        let nonces = MemoryWarrantNonceStore()
        _ = nonces.next(relay: relay)
        let signIn = CloudSignIn(
            config: CloudConfig(cloudBaseURL: DelegatedFixture.cloud, sealRelays: false), keyStore: keys,
            sessionStore: sessions, nonces: nonces, urlSession: MockURLProtocol.makeSession(), delegatedStore: store)
        return SignedIn(
            signIn: signIn, keys: keys, sessions: sessions, store: store, nonces: nonces, account: session.account)
    }

    func testSignOutForgetsTheAccountButKeepsTheDeviceAndItsNonces() async {
        let rig = signedIn()
        await rig.signIn.signOut()

        XCTAssertNil(rig.sessions.load())
        XCTAssertEqual(rig.store.relayMap(account: rig.account), RelayMap())
        XCTAssertEqual(rig.store.groupNamespaces(account: rig.account), [:])
        XCTAssertNil(rig.store.pinnedRelayNodeKey(relayURL: relay), "the session's relay")
        XCTAssertNil(rig.store.pinnedRelayNodeKey(relayURL: otherRelay), "a relay in its map")
        XCTAssertEqual(rig.keys.load(), DelegatedFixture.keys, "the device key stays")
        XCTAssertEqual(rig.nonces.next(relay: relay), 2, "nonces spent under that key stay with it")
    }

    func testSignOutForgettingTheDeviceDropsItsKeysAndNonces() async {
        let rig = signedIn()
        await rig.signIn.signOut(forgetDevice: true)

        XCTAssertNil(rig.sessions.load())
        XCTAssertEqual(rig.store.relayMap(account: rig.account), RelayMap())
        XCTAssertNil(rig.store.pinnedRelayNodeKey(relayURL: relay))
        XCTAssertNil(rig.keys.load(), "the next sign-in certifies a fresh key")
        XCTAssertEqual(rig.nonces.next(relay: relay), 1, "a fresh key starts a fresh sequence")
    }
}

/// A lock-protected value, for collecting from `@Sendable` callbacks.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func mutate(_ change: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&stored)
    }
}
