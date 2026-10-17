import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

struct AsyncResourceBoom: Error {}

/// A one-shot gate a fetcher waits on, so a test decides the order answers land.
final class AsyncResourceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

/// `useAsyncResource` / `useAsyncMutation` and the read hooks built on them
/// (mero-react `hooks/index.test.tsx`, `stale-data.test.tsx`).
@MainActor
final class AsyncResourceTests: XCTestCase {
    func testADisabledReadStaysAtItsInitialValue() async {
        let resource = AsyncResource<[String]>(initial: [])
        await resource.refetch()
        XCTAssertEqual(resource.data, [])
        XCTAssertFalse(resource.isLoading)
        XCTAssertFalse(resource.isEnabled)
    }

    func testTheLatestRequestWins() async {
        let slow = AsyncResourceGate()
        let resource = AsyncResource<String>(initial: "", autoload: false)
        resource.setFetcher {
            await slow.wait()
            return "old"
        }
        let started = await appLayerEventually { resource.isLoading }
        XCTAssertTrue(started)
        // New input: the old answer must never land.
        resource.setFetcher { "new" }
        XCTAssertEqual(resource.data, "", "reset to the initial value at once")
        let fresh = await appLayerEventually { resource.data == "new" }
        XCTAssertTrue(fresh)
        slow.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(resource.data, "new")
        XCTAssertFalse(resource.isLoading)
    }

    func testAFailureIsRecordedAndClearedByTheNextRead() async {
        let resource = AsyncResource<Int>(initial: 0, autoload: false)
        resource.setFetcher { throw AsyncResourceBoom() }
        let failed = await appLayerEventually { resource.error != nil }
        XCTAssertTrue(failed)
        resource.setFetcher { 7 }
        XCTAssertNil(resource.error)
        let loaded = await appLayerEventually { resource.data == 7 }
        XCTAssertTrue(loaded)
    }

    func testAMutationRecordsAndOptionallyRethrows() async throws {
        let mutation = AsyncMutation()
        let conflict = HTTPError(status: 409, statusText: "Conflict", url: "u", headers: [:])
        let none: Int? = try await mutation.run { () -> Int in throw conflict }
        XCTAssertNil(none)
        XCTAssertEqual(mutation.failure?.status, 409)
        XCTAssertFalse(mutation.isLoading)

        let throwing = AsyncMutation(throwOnError: true)
        do {
            let forbidden = HTTPError(status: 403, statusText: "", url: "u", headers: [:])
            _ = try await throwing.run { () -> Int in throw forbidden }
            XCTFail("throwOnError must rethrow")
        } catch let error as HTTPError {
            XCTAssertEqual(error.status, 403, "the original error, with its status")
        }
        XCTAssertEqual(throwing.failure?.kind, .forbidden)
    }

    func testReadsFollowTheSession() async {
        let node = AppLayerNode()
        node.contextList = [AppLayerNode.context("c1", app: "a1"), AppLayerNode.context("c2", app: "a2")]
        node.install()
        defer { MockURLProtocol.reset() }
        let session = MockURLProtocol.makeSession()
        let client = MeroClient(
            session: session, webAuthenticator: AppLayerLoginSheet(nodeURL: "https://node.reads.test"),
            storage: MeroAppStorage(defaults: appLayerDefaults()), authStateStore: AuthLoginStateStore())

        let contexts = client.contexts()
        XCTAssertFalse(contexts.isEnabled, "no admin yet: nothing is read")

        await client.connectToNode("https://node.reads.test", callbackScheme: "myapp")
        let listed = await appLayerEventually { contexts.data.count == 2 }
        XCTAssertTrue(listed)
        XCTAssertEqual(contexts.data.first, ApplicationContextRecord(contextId: "c1", applicationId: "a1"))

        await client.logout()
        let cleared = await appLayerEventually { contexts.data.isEmpty && !contexts.isEnabled }
        XCTAssertTrue(cleared, "a session change re-derives the read")
    }

    func testMigrationStatusPollsWhileTheStreamIsDown() async {
        let node = AppLayerNode()
        node.install()
        defer { MockURLProtocol.reset() }
        let client = MeroClient(
            session: MockURLProtocol.makeSession(),
            webAuthenticator: AppLayerLoginSheet(nodeURL: "https://node.migration.test"),
            storage: MeroAppStorage(defaults: appLayerDefaults()), authStateStore: AuthLoginStateStore())
        await client.connectToNode("https://node.migration.test", callbackScheme: "myapp")
        let model = MigrationStatusModel(
            client: client, namespaceId: "ns1", pollInterval: 0.01, sleep: { _ in await Task.yield() })
        let loaded = await appLayerEventually { model.status != nil }
        XCTAssertTrue(loaded)
        XCTAssertTrue(model.allMigrated)
        XCTAssertEqual(model.members.count, 0)
        let polled = await appLayerEventually { node.migrationReads >= 3 }
        XCTAssertTrue(polled, "an explicit interval always polls")
        model.stop()
        await client.logout()
    }

    func testGroupAppVersionZeroKeys() {
        XCTAssertTrue(GroupAppVersionModel.isZeroAppKey(nil))
        XCTAssertTrue(GroupAppVersionModel.isZeroAppKey(""))
        XCTAssertTrue(GroupAppVersionModel.isZeroAppKey("0000"))
        XCTAssertFalse(GroupAppVersionModel.isZeroAppKey("00a0"))
    }

    func testBlobNotFoundReadsTheStatus() {
        let missing = MeroError.http(HTTPError(status: 404, statusText: "", url: "u", headers: [:]))
        XCTAssertTrue(isBlobNotFound(missing))
        XCTAssertFalse(isBlobNotFound(MeroError.network("down")))
        XCTAssertFalse(isBlobNotFound(nil))
    }
}
