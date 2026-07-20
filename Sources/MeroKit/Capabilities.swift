import Foundation

/// Member capability bitmask constants — mirrors core's `MemberCapabilities`
/// (crates/context/config/src/lib.rs). The per-member value is a `UInt32`
/// bitmask. Core currently assigns bits 0...8 (below); bits 9 and above are
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
