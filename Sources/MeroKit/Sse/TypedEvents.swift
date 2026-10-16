import Foundation

// Typed views of the events an SSE or WebSocket stream delivers, decoded from
// the frame's `result` exactly as core serializes it
// (`calimero_primitives::events`): a `type` tag beside a `data` payload.
// (== mero-js `events/group.ts` and `AppVersionChangedEvent`.)

/// A context's application bundle changed version (`AppVersionChanged`).
public struct AppVersionChangedEvent: Sendable, Equatable {
    public let contextId: String
    /// The version before, when core knew it.
    public let fromVersion: String?
    /// The version now, when core knew it.
    public let toVersion: String?

    public init(contextId: String, fromVersion: String?, toVersion: String?) {
        self.contextId = contextId
        self.fromVersion = fromVersion
        self.toVersion = toVersion
    }
}

/// Which membership change a ``GroupMembershipEvent`` reports. A member who
/// left and one an admin removed both arrive as ``memberRemoved``.
public enum MembershipChangeKind: String, Sendable, Equatable, CaseIterable {
    /// Joined through a self-service path (an open invitation, or inherited
    /// from an Open subgroup).
    case memberJoined = "MemberJoined"
    /// An admin added the member.
    case memberAdded = "MemberAdded"
    /// Removed, or left.
    case memberRemoved = "MemberRemoved"
}

/// A group's membership changed (core's `GroupMembershipEvent`).
public struct GroupMembershipEvent: Sendable, Equatable {
    /// The group whose membership changed, hex.
    public let groupId: String
    public let kind: MembershipChangeKind
    /// The member's ACCOUNT, hex (64 chars) — the principal governance rows
    /// name, never a signing key.
    public let memberAccount: String
    /// `Admin`, `Member`, `ReadOnly`, `ReadOnlyTee` or `RelayTee`. Absent on
    /// `MemberRemoved`, and on a `MemberJoined` inherited from an Open subgroup.
    public let role: String?

    public init(groupId: String, kind: MembershipChangeKind, memberAccount: String, role: String?) {
        self.groupId = groupId
        self.kind = kind
        self.memberAccount = memberAccount
        self.role = role
    }
}

/// A migration was accepted and its target ABI state version resolved.
public struct MigrationStartedData: Codable, Sendable, Equatable {
    public let fromVersion: String
    public let toVersion: String
    /// The `#[app::state(version = N)]` number, not the bundle semver.
    public let toStateVersion: UInt32
    /// Contexts the EMITTING NODE enumerated for the migration. Node-local,
    /// never the fleet cohort size ``MigrationProgressData/total`` carries.
    public let localContextsTotal: UInt32

    public init(fromVersion: String, toVersion: String, toStateVersion: UInt32, localContextsTotal: UInt32) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.toStateVersion = toStateVersion
        self.localContextsTotal = localContextsTotal
    }
}

/// Fleet rollup counters, recomputed as peers' heartbeat facts change.
public struct MigrationProgressData: Codable, Sendable, Equatable {
    public let migrated: Int
    public let inProgress: Int
    public let unknown: Int
    public let failed: Int
    /// The pinned FLEET COHORT size, never a node-local context count.
    public let total: Int

    public init(migrated: Int, inProgress: Int, unknown: Int, failed: Int, total: Int) {
        self.migrated = migrated
        self.inProgress = inProgress
        self.unknown = unknown
        self.failed = failed
        self.total = total
    }
}

/// One subgroup's local context swaps advanced on the emitting node.
///
/// Admin-only: it names a descendant subgroup, which a plain member may not
/// enumerate, so core withholds it from non-admin subscribers. A non-admin
/// never receiving it is correct behaviour.
public struct CascadeProgressData: Codable, Sendable, Equatable {
    /// The descendant subgroup, hex — never the namespace root the event is keyed on.
    public let subgroupId: String
    public let localContextsSwapped: UInt32
    /// Contexts the emitting node holds for THIS SUBGROUP.
    public let localContextsTotal: UInt32

    public init(subgroupId: String, localContextsSwapped: UInt32, localContextsTotal: UInt32) {
        self.subgroupId = subgroupId
        self.localContextsSwapped = localContextsSwapped
        self.localContextsTotal = localContextsTotal
    }
}

/// Every pinned-cohort member reported the target version.
public struct MigrationCompletedData: Codable, Sendable, Equatable {
    public let toVersion: String
    /// FLEET convergence, seconds since the epoch (the stamp
    /// `MigrationStatus.fleetCompletedAt` returns).
    public let completedAt: UInt64

    public init(toVersion: String, completedAt: UInt64) {
        self.toVersion = toVersion
        self.completedAt = completedAt
    }
}

/// A namespace migration changed phase (core's `GroupMigrationEvent`), keyed
/// on the namespace root a client subscribes with.
///
/// `migrationStarted`, `migrationProgress` and `migrationCompleted` reach every
/// subscribed member; `cascadeProgress` reaches namespace admins only.
public enum GroupMigrationEvent: Sendable, Equatable {
    case migrationStarted(groupId: String, MigrationStartedData)
    case migrationProgress(groupId: String, MigrationProgressData)
    case cascadeProgress(groupId: String, CascadeProgressData)
    case migrationCompleted(groupId: String, MigrationCompletedData)

    /// The `type` tags of this family.
    public static let kinds: Set<String> = [
        "MigrationStarted", "MigrationProgress", "CascadeProgress", "MigrationCompleted",
    ]

    /// The namespace root the event is keyed on, hex.
    public var groupId: String {
        switch self {
        case .migrationStarted(let groupId, _), .migrationProgress(let groupId, _),
            .cascadeProgress(let groupId, _), .migrationCompleted(let groupId, _):
            return groupId
        }
    }

    /// The wire `type` tag.
    public var kind: String {
        switch self {
        case .migrationStarted: return "MigrationStarted"
        case .migrationProgress: return "MigrationProgress"
        case .cascadeProgress: return "CascadeProgress"
        case .migrationCompleted: return "MigrationCompleted"
        }
    }
}

// MARK: - Decoding

extension ContextEvent {
    /// The frame's `data`, decoded as mero-js decodes it: a byte array that
    /// holds UTF-8 JSON becomes that JSON; anything else is returned as is.
    public var data: JSONValue? { EventData.decode(payload["data"]) }

    /// The event as an ``AppVersionChangedEvent``, or `nil` for another kind.
    public var appVersionChanged: AppVersionChangedEvent? {
        guard kind == "AppVersionChanged" else { return nil }
        let data = self.data
        return AppVersionChangedEvent(
            contextId: contextId, fromVersion: data?["fromVersion"]?.stringValue,
            toVersion: data?["toVersion"]?.stringValue)
    }
}

extension GroupEvent {
    /// The frame's `data`, decoded like ``ContextEvent/data``.
    public var data: JSONValue? { EventData.decode(payload["data"]) }

    /// The event as a ``GroupMembershipEvent``, or `nil` for another kind (or
    /// a payload without `memberAccount`).
    public var membership: GroupMembershipEvent? {
        let data = self.data
        guard let change = MembershipChangeKind(rawValue: kind),
            let account = data?["memberAccount"]?.stringValue
        else { return nil }
        return GroupMembershipEvent(
            groupId: groupId, kind: change, memberAccount: account, role: data?["role"]?.stringValue)
    }

    /// The event as a ``GroupMigrationEvent``, or `nil` for another kind (or
    /// a payload that does not match core's shape).
    public var migration: GroupMigrationEvent? {
        guard GroupMigrationEvent.kinds.contains(kind), let data = self.data else { return nil }
        let groupId = self.groupId
        switch kind {
        case "MigrationStarted":
            guard let started = EventData.decode(MigrationStartedData.self, data) else { return nil }
            return .migrationStarted(groupId: groupId, started)
        case "MigrationProgress":
            guard let progress = EventData.decode(MigrationProgressData.self, data) else { return nil }
            return .migrationProgress(groupId: groupId, progress)
        case "CascadeProgress":
            guard let cascade = EventData.decode(CascadeProgressData.self, data) else { return nil }
            return .cascadeProgress(groupId: groupId, cascade)
        default:
            guard let completed = EventData.decode(MigrationCompletedData.self, data) else { return nil }
            return .migrationCompleted(groupId: groupId, completed)
        }
    }
}

enum EventData {
    /// A byte array of UTF-8 JSON becomes that JSON; anything else is kept.
    static func decode(_ value: JSONValue?) -> JSONValue? {
        guard case .array(let items)? = value, !items.isEmpty else { return value }
        var bytes = [UInt8]()
        bytes.reserveCapacity(items.count)
        for item in items {
            guard case .number(let n) = item, n >= 0, n <= 255, n == n.rounded() else { return value }
            bytes.append(UInt8(n))
        }
        return (try? MeroJSON.decode(JSONValue.self, from: Data(bytes))) ?? value
    }

    /// `value` decoded into `T`. Integral numbers are written without a
    /// fraction (``CanonicalJSON``), so integer fields decode.
    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) -> T? {
        try? MeroJSON.decode(type, from: CanonicalJSON.data(value))
    }
}
