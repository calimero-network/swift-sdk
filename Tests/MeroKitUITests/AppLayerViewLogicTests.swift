#if canImport(SwiftUI)
import MeroKit
import SwiftUI
import XCTest

@testable import MeroKitUI

/// The logic behind the views: dialog stages and copy (mero-react
/// `InvitationDialog.test.tsx`), the logged-out gate (`InvitationGate.test.tsx`),
/// the node tab's URL rules (`LoginModal.test.tsx`), the logo, the theme.
@MainActor
final class AppLayerViewLogicTests: XCTestCase {
    func testDialogStages() {
        XCTAssertNil(InvitationDialogStage.resolve(.idle, flagged: false), "nothing while there is no invitation")
        XCTAssertEqual(
            InvitationDialogStage.resolve(.awaitingConfirmation(teamName: nil), flagged: false), .awaitingConfirmation)
        XCTAssertEqual(InvitationDialogStage.resolve(.joined(namespaceId: "n", teamName: nil), flagged: true), .syncing)
        XCTAssertEqual(InvitationDialogStage.resolve(.joined(namespaceId: "n", teamName: nil), flagged: false), .ready)
        XCTAssertTrue(InvitationDialogStage.joining.isBusy, "cannot be closed mid-join")
        XCTAssertTrue(InvitationDialogStage.syncing.isBusy)
        XCTAssertFalse(InvitationDialogStage.failed.isBusy)
    }

    func testDialogCopy() {
        let ask = InvitationDialogCopy.make(
            stage: .awaitingConfirmation, state: .awaitingConfirmation(teamName: "Design team"))
        XCTAssertEqual(ask.title, "Join “Design team”?")
        let own = InvitationDialogCopy.make(
            stage: .awaitingConfirmation, state: .awaitingConfirmation(teamName: nil), noun: "vault",
            detail: "Joining gives you this vault.")
        XCTAssertEqual(own.title, "Join this vault?")
        XCTAssertEqual(own.body, "Joining gives you this vault.")
        let step = InvitationDialogCopy.make(stage: .joining, state: .joining(teamName: "T"), status: "Signing…")
        XCTAssertEqual(step.title, "Joining “T”…")
        XCTAssertEqual(step.body, "Signing…")
        let slow = InvitationDialogCopy.make(
            stage: .syncing, state: .joined(namespaceId: "n", teamName: nil), slow: true)
        XCTAssertTrue(slow.body?.hasPrefix("Still waiting") == true)

        let expired = InviteState.failed(message: "HTTP 410", reason: .expired, retryable: false)
        let failure = InvitationDialogCopy.make(stage: .failed, state: expired)
        XCTAssertEqual(failure.body, "This invitation has expired. Ask for a new link.")
        let unknown = InviteState.failed(message: "the node's own words", reason: .unknown, retryable: true)
        XCTAssertEqual(InvitationDialogCopy.make(stage: .failed, state: unknown).body, "the node's own words")
        let member = InviteState.alreadyMember(namespaceId: "n", teamName: "T")
        XCTAssertEqual(InvitationDialogCopy.make(stage: .alreadyMember, state: member).title, "You're already in “T”")
    }

    private func gate(
        pending: Bool, failed: Bool = false, authed: Bool = false, loading: Bool = false
    ) -> InvitationGateState? {
        InvitationGateState.resolve(
            hasPending: pending, parseFailed: failed, isAuthenticated: authed, isLoading: loading)
    }

    func testTheGateShowsOnlyWhileLoggedOutWithAPendingInvitation() {
        XCTAssertNil(gate(pending: false))
        XCTAssertNil(gate(pending: true, authed: true), "logged in: the dialog asks instead")
        XCTAssertEqual(gate(pending: true, loading: true), .checking)
        XCTAssertEqual(gate(pending: true), .invited)
        XCTAssertEqual(gate(pending: true, failed: true), .invalid)
        let named = InvitationGate<EmptyView>.copy(.invited, teamName: "Design team", noun: "team", appName: "Docs")
        XCTAssertEqual(named.title, "You're invited to join “Design team”")
        XCTAssertTrue(named.body?.contains("in Docs") == true)
        XCTAssertEqual(
            InvitationGate<EmptyView>.copy(.invited, teamName: nil, noun: "space", appName: nil).title,
            "You're invited to join a space")
    }

    func testNodeURLValidation() {
        XCTAssertTrue(NodeLoginModel.isValidNodeURL("localhost:2428"))
        XCTAssertTrue(NodeLoginModel.isValidNodeURL("http://192.168.1.10:2428"))
        XCTAssertTrue(NodeLoginModel.isValidNodeURL("https://node.calimero.network"))
        XCTAssertFalse(NodeLoginModel.isValidNodeURL(""))
        XCTAssertFalse(NodeLoginModel.isValidNodeURL("ftp://node.example"))
        XCTAssertFalse(NodeLoginModel.isValidNodeURL("http://999.1.1.1"))
        XCTAssertFalse(NodeLoginModel.isValidNodeURL("https://bad_host!"))
        XCTAssertEqual(NodeLoginModel.display("http://localhost:2428/"), "localhost:2428")
        XCTAssertEqual(NodeLoginModel.normalized("node.example"), "https://node.example")
    }

    func testAChosenDiscoveredNodeConnectsWithoutAProbe() async {
        let model = NodeLoginModel(ports: [])
        model.selected = "http://localhost:2428"
        XCTAssertTrue(model.canConnect)
        let target = await model.resolveTarget()
        XCTAssertEqual(target, "http://localhost:2428")
        model.selected = nil
        model.customURL = "not a url"
        XCTAssertFalse(model.canConnect)
    }

    func testTheLogoPathFillsItsViewBox() {
        let bounds = CalimeroLogoShape().path(in: CGRect(x: 0, y: 0, width: 193, height: 193)).boundingRect
        XCTAssertGreaterThan(bounds.width, 180)
        XCTAssertGreaterThan(bounds.height, 180)
        XCTAssertGreaterThanOrEqual(bounds.minX, 0)
        XCTAssertLessThanOrEqual(bounds.maxX, 193)
        let half = CalimeroLogoShape().path(in: CGRect(x: 0, y: 0, width: 96.5, height: 96.5)).boundingRect
        XCTAssertEqual(half.width, bounds.width / 2, accuracy: 0.5)
    }

    func testTheDefaultThemeIsCalimeroGreen() {
        XCTAssertEqual(defaultMeroTheme.radius, 8)
        let tweaked = defaultMeroTheme.with { $0.radius = 12 }
        XCTAssertEqual(tweaked.radius, 12)
    }

    func testSmallFormatting() {
        XCTAssertEqual(ConnectButton.shortAccount(String(repeating: "ab", count: 32)), "ababab…ababab")
        XCTAssertEqual(MigrationPendingBannerContent.prompt(1), "You have 1 entry to re-sign after a recent upgrade.")
        XCTAssertEqual(MigrationPendingBannerContent.prompt(3), "You have 3 entries to re-sign after a recent upgrade.")
    }
}
#endif
