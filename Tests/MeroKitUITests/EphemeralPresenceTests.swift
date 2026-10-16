import MeroKit
import XCTest

@testable import MeroKitUI

struct EphemeralPresenceCursor: Codable, Sendable, Equatable {
    var x: Int
    var y: Int
}

/// The settable clock the presence tests read.
final class EphemeralPresenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// `useEphemeral`'s read side (mero-react `hooks/ephemeral.test.tsx`): the
/// replay is authoritative, removals drop a peer, ages count from the node's.
@MainActor
final class EphemeralPresenceTests: XCTestCase {
    private func entry(
        _ author: String, x: Int = 0, removed: Bool = false, ageMs: UInt64? = nil
    ) -> EphemeralEntry<EphemeralPresenceCursor> {
        EphemeralEntry(
            author: author, state: removed ? nil : EphemeralPresenceCursor(x: x, y: 0), removed: removed, ageMs: ageMs)
    }

    private func makePresence(clock: EphemeralPresenceClock) -> EphemeralPresence<EphemeralPresenceCursor> {
        let client = MeroClient(storage: MeroAppStorage(defaults: appLayerDefaults()))
        return EphemeralPresence(
            client: client, contextId: "ctx", initial: EphemeralPresenceCursor(x: 0, y: 0),
            sleep: { _ in await Task.yield() }, now: { clock.now })
    }

    func testLiveEntriesUpsertAndRemovalsDrop() {
        let presence = makePresence(clock: EphemeralPresenceClock())
        presence.apply(entry("a", x: 1))
        presence.apply(entry("b", x: 2))
        presence.apply(entry("a", x: 3))
        XCTAssertEqual(presence.peers["a"], EphemeralPresenceCursor(x: 3, y: 0))
        presence.apply(entry("b", removed: true))
        XCTAssertNil(presence.peers["b"])
        XCTAssertNil(presence.ageOf("b"))
    }

    func testAReplayDropsPeersItDoesNotMention() async {
        let presence = makePresence(clock: EphemeralPresenceClock())
        presence.apply(entry("ghost", x: 9))
        presence.apply(entry("a", x: 1, ageMs: 100))
        presence.apply(entry("b", x: 2, ageMs: 0))
        let reconciled = await appLayerEventually { presence.peers["ghost"] == nil }
        XCTAssertTrue(reconciled, "a peer swept while disconnected does not survive the replay")
        XCTAssertEqual(Set(presence.peers.keys), ["a", "b"])
    }

    func testAgeCountsFromWhenTheNodeLastHeardThePeer() {
        let clock = EphemeralPresenceClock()
        let presence = makePresence(clock: clock)
        presence.apply(entry("a", ageMs: 2_000))
        presence.apply(entry("b"))
        clock.advance(1)
        let ageA = presence.ageOf("a") ?? -1
        let ageB = presence.ageOf("b") ?? -1
        XCTAssertEqual(ageA, 3, accuracy: 0.001)
        XCTAssertEqual(ageB, 1, accuracy: 0.001, "a live delta is current as of its receipt")
    }
}
