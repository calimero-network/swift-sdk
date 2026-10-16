import XCTest

@testable import MeroKit

/// Presets and name helpers. (Port of mero-js `capabilities.test.ts`.)
final class CapabilityPresetsTests: XCTestCase {
    func testPresetValues() {
        XCTAssertEqual(CapabilityPresets.none, 0)
        XCTAssertEqual(CapabilityPresets.joinOnly, 4)
        XCTAssertEqual(CapabilityPresets.contributor, 7)
        XCTAssertEqual(CapabilityPresets.collaborator, 231)
        XCTAssertEqual(
            CapabilityPresets.byName, ["NONE": 0, "JOIN_ONLY": 4, "CONTRIBUTOR": 7, "COLLABORATOR": 231])
    }

    func testNoPresetGrantsAuthorshipOnBehalf() {
        for mask in CapabilityPresets.byName.values {
            XCTAssertFalse(Capabilities.hasCap(mask, Capabilities.canAuthorOnBehalf))
        }
    }

    func testCapMaskCombinesNamesAndBitValues() throws {
        XCTAssertEqual(try Capabilities.capMask(), 0)
        XCTAssertEqual(try Capabilities.capMask("CAN_CREATE_CONTEXT", "CAN_INVITE_MEMBERS"), 3)
        XCTAssertEqual(try Capabilities.capMask("CAN_CREATE_CONTEXT", .bits(Capabilities.canCreateContext)), 1)
        XCTAssertEqual(try Capabilities.capMask(.bits(CapabilityPresets.contributor), "CAN_CREATE_SUBGROUP"), 39)
        XCTAssertEqual(try Capabilities.capMask(.bits(1 << 31)), 0x8000_0000)
        XCTAssertEqual(try Capabilities.capMask(256), Capabilities.canManageMetadata, "an integer literal is bits")
    }

    func testCapMaskRefusesAnUnknownName() {
        XCTAssertThrowsError(try Capabilities.capMask("CAN_CREATE_CONTEXTS")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("unknown capability"))
        }
        XCTAssertThrowsError(try Capabilities.capMask("toString"))
    }

    func testCapNamesListsTheAssignedBitsInBitOrder() throws {
        XCTAssertEqual(Capabilities.capNames(0), [])
        XCTAssertEqual(
            Capabilities.capNames(CapabilityPresets.collaborator),
            [
                "CAN_CREATE_CONTEXT", "CAN_INVITE_MEMBERS", "CAN_JOIN_OPEN_SUBGROUPS", "CAN_CREATE_SUBGROUP",
                "CAN_DELETE_SUBGROUP", "CAN_MANAGE_VISIBILITY",
            ])
        XCTAssertEqual(
            Capabilities.capNames(Capabilities.withCap(Capabilities.canAuthorOnBehalf, 1 << 31)),
            ["CAN_AUTHOR_ON_BEHALF"])
        let names = Capabilities.capNames(CapabilityPresets.collaborator).map { CapabilityRef.name($0) }
        XCTAssertEqual(try Capabilities.capMask(names), 231)
    }

    func testEveryAssignedBitHasAName() {
        XCTAssertEqual(Capabilities.all.count, 10)
        for (index, entry) in Capabilities.all.enumerated() {
            XCTAssertEqual(entry.bit, UInt32(1) << UInt32(index), entry.name)
            XCTAssertEqual(Capabilities.bit(named: entry.name), entry.bit)
        }
        XCTAssertNil(Capabilities.bit(named: "NOPE"))
    }
}
