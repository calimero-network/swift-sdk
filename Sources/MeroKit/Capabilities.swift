import Foundation

/// Member capability bitmask constants — mirrors core's `MemberCapabilities`
/// (crates/context/config/src/lib.rs). The per-member value is a `UInt32`
/// bitmask. Core currently assigns bits 0...9 (below); bits 10 and above are
/// unassigned and may be claimed by future core versions — an application MUST
/// NOT repurpose them.
public enum Capabilities {
    public static let canCreateContext: UInt32 = 1 << 0
    public static let canInviteMembers: UInt32 = 1 << 1
    public static let canJoinOpenSubgroups: UInt32 = 1 << 2
    public static let manageMembers: UInt32 = 1 << 3
    public static let manageApplication: UInt32 = 1 << 4
    public static let canCreateSubgroup: UInt32 = 1 << 5
    public static let canDeleteSubgroup: UInt32 = 1 << 6
    public static let canManageVisibility: UInt32 = 1 << 7
    public static let canManageMetadata: UInt32 = 1 << 8
    /// May execute intents (warranted writes) on another member's behalf — the
    /// grant a relay node needs. Implied by neither membership nor admin, and
    /// not propagated to subgroups. See ``AdminApi/openToDelegatedExecution(_:)``
    /// and ``AdminApi/grantAuthorship(_:account:)``.
    ///
    /// Never changed through a relay: the governance op builders refuse a mask
    /// that sets it.
    public static let canAuthorOnBehalf: UInt32 = 1 << 9

    /// Every capability core assigns, by its mero-js name, in bit order.
    /// (== the keys of mero-js `CAPABILITIES`.)
    public static let all: [(name: String, bit: UInt32)] = [
        ("CAN_CREATE_CONTEXT", canCreateContext),
        ("CAN_INVITE_MEMBERS", canInviteMembers),
        ("CAN_JOIN_OPEN_SUBGROUPS", canJoinOpenSubgroups),
        ("MANAGE_MEMBERS", manageMembers),
        ("MANAGE_APPLICATION", manageApplication),
        ("CAN_CREATE_SUBGROUP", canCreateSubgroup),
        ("CAN_DELETE_SUBGROUP", canDeleteSubgroup),
        ("CAN_MANAGE_VISIBILITY", canManageVisibility),
        ("CAN_MANAGE_METADATA", canManageMetadata),
        ("CAN_AUTHOR_ON_BEHALF", canAuthorOnBehalf),
    ]

    /// The bit core assigns to `name` (`"CAN_CREATE_CONTEXT"`), or `nil` for a
    /// name it does not assign.
    public static func bit(named name: String) -> UInt32? {
        all.first { $0.name == name }?.bit
    }

    /// A mask from capability names and/or bit values:
    /// `capMask("CAN_CREATE_CONTEXT", "CAN_INVITE_MEMBERS") == 3`.
    /// Throws on a name core does not assign, so a typo can't silently yield 0.
    /// (== mero-js `capMask`.)
    public static func capMask(_ caps: CapabilityRef...) throws -> UInt32 {
        try capMask(caps)
    }

    /// `capMask` over an array.
    public static func capMask(_ caps: [CapabilityRef]) throws -> UInt32 {
        var mask: UInt32 = 0
        for cap in caps {
            switch cap {
            case .bits(let bits):
                mask |= bits
            case .name(let name):
                guard let assigned = Self.bit(named: name) else {
                    throw AccountError.invalidInput("unknown capability: \(name)")
                }
                mask |= assigned
            }
        }
        return mask
    }

    /// The names of the assigned capability bits set in `mask`, in bit order.
    /// Unassigned bits (10 and above) are not reported. (== mero-js `capNames`.)
    public static func capNames(_ mask: UInt32) -> [String] {
        all.filter { hasCap(mask, $0.bit) }.map { $0.name }
    }

    /// True if `mask` has every bit of `cap` set. (== mero-js `hasCap`.)
    public static func hasCap(_ mask: UInt32, _ cap: UInt32) -> Bool {
        (mask & cap) == cap
    }

    /// `mask` with every bit of `cap` set. (== mero-js `withCap`.)
    public static func withCap(_ mask: UInt32, _ cap: UInt32) -> UInt32 {
        mask | cap
    }

    /// `mask` with every bit of `cap` cleared. (== mero-js `withoutCap`.)
    public static func withoutCap(_ mask: UInt32, _ cap: UInt32) -> UInt32 {
        mask & ~cap
    }
}

/// A capability named or given as bits, for `Capabilities.capMask`.
/// A string literal is a name, an integer literal bits:
/// `try Capabilities.capMask("CAN_CREATE_CONTEXT", .bits(Capabilities.canCreateSubgroup), 256)`.
public enum CapabilityRef: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    /// A name core assigns, as mero-js spells it (`"CAN_INVITE_MEMBERS"`).
    case name(String)
    /// Raw bits, OR-ed in as they are.
    case bits(UInt32)

    public init(stringLiteral value: String) { self = .name(value) }
    public init(integerLiteral value: UInt32) { self = .bits(value) }
}

/// Ready-made masks for `setDefaultCapabilities` / `setMemberCapabilities`, so
/// an app can name the default it gives members instead of passing a bare
/// number. (== mero-js `CAPABILITY_PRESETS`.)
///
/// Why this matters: a namespace's default mask is copied into a non-admin
/// member's row when they join, and a namespace starts without
/// ``Capabilities/canCreateContext`` in it. An app that never sets a default
/// leaves every invited member unable to create a context until an admin
/// grants it by hand.
///
/// None of these include ``Capabilities/canAuthorOnBehalf``; grant that
/// deliberately (``AdminApi/grantAuthorship(_:account:)``).
public enum CapabilityPresets {
    /// No capabilities.
    public static let none: UInt32 = 0
    /// Join Open subgroups only: what a namespace starts with (= 4).
    public static let joinOnly: UInt32 = Capabilities.canJoinOpenSubgroups
    /// Create contexts, invite members, join Open subgroups (= 7). A member who
    /// can work in the namespace but not reshape it.
    public static let contributor: UInt32 =
        Capabilities.canCreateContext | Capabilities.canInviteMembers | Capabilities.canJoinOpenSubgroups
    /// ``contributor`` plus create and delete subgroups and manage their
    /// visibility (= 231). What mero-chat gives members, so they can start and
    /// close their own channels.
    public static let collaborator: UInt32 =
        contributor | Capabilities.canCreateSubgroup | Capabilities.canDeleteSubgroup | Capabilities.canManageVisibility

    /// Every preset by its mero-js name (`NONE`, `JOIN_ONLY`, `CONTRIBUTOR`,
    /// `COLLABORATOR`).
    public static let byName: [String: UInt32] = [
        "NONE": none, "JOIN_ONLY": joinOnly, "CONTRIBUTOR": contributor, "COLLABORATOR": collaborator,
    ]
}
