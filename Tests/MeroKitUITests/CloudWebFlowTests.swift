import MeroKit
import XCTest

@testable import MeroKitUI

/// A system auth sheet that records the page it was shown and answers with
/// whatever `respond` makes of it.
private final class CloudPageSheet: WebAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [URL] = []
    private let respond: @Sendable (URL) throws -> URL

    init(respond: @escaping @Sendable (URL) throws -> URL) {
        self.respond = respond
    }

    var pages: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return shown
    }

    private func record(_ url: URL) {
        lock.lock()
        shown.append(url)
        lock.unlock()
    }

    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        record(url)
        return try respond(url)
    }
}

final class CloudWebFlowTests: XCTestCase {
    private let account = String(repeating: "1f", count: 32)

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func testEnableHAOpensThePageWithTheCallbackAsItsRedirect() async throws {
        let sheet = CloudPageSheet { _ in URL(string: "mero-sample://ha?status=enabled")! }
        let cloud = CloudClient(baseURL: URL(string: "https://cloud.example")!)
        let back = try await cloud.enableHA(
            HAPageOptions(groupId: "g", contextId: "c"), callback: .scheme("mero-sample", path: "ha"),
            authenticator: sheet)
        XCTAssertEqual(back.query, "status=enabled")
        let page = try XCTUnwrap(sheet.pages.first)
        XCTAssertEqual(page.path, "/enable-ha")
        XCTAssertEqual(Self.query(page, "group_id"), "g")
        XCTAssertEqual(Self.query(page, "context_id"), "c")
        XCTAssertEqual(Self.query(page, "redirect_url"), "mero-sample://ha")
    }

    func testDisableHAKeepsAnExplicitRedirect() async throws {
        let sheet = CloudPageSheet { $0 }
        let cloud = CloudClient(baseURL: URL(string: "https://cloud.example")!)
        _ = try await cloud.disableHA(
            HAPageOptions(groupId: "g", contextId: "c", redirectUrl: "https://app.example/done"),
            callback: .scheme("mero-sample", path: "ha"), authenticator: sheet)
        let page = try XCTUnwrap(sheet.pages.first)
        XCTAssertEqual(page.path, "/disable-ha")
        XCTAssertEqual(Self.query(page, "redirect_url"), "https://app.example/done")
    }

    func testBeginCloudLinkReadsTheGrantTheConsentPageSendsBack() async throws {
        let account = self.account
        let sheet = CloudPageSheet { consent in
            let back = try XCTUnwrap(Self.query(consent, "callback-url"))
            return try XCTUnwrap(URL(string: "\(back)#grant=sealed.grant&account=\(account)"))
        }
        let store = CloudLinkStateStore()
        let grant = try await CloudLink.beginCloudLink(
            accountId: account, callback: .scheme("mero-sample", path: "link"), stateStore: store,
            authenticator: sheet)
        XCTAssertEqual(grant, CloudLinkCallback(grant: "sealed.grant", account: account))
        let consent = try XCTUnwrap(sheet.pages.first)
        XCTAssertEqual(consent.host, "cloud.calimero.network")
        XCTAssertEqual(Self.query(consent, "link-account"), account)
        XCTAssertEqual(store.pendingCount(), 0, "the state is spent")
    }

    func testBeginCloudLinkReportsADecline() async {
        let sheet = CloudPageSheet { _ in URL(string: "mero-sample://link#error=denied")! }
        do {
            _ = try await CloudLink.beginCloudLink(
                accountId: account, callback: .scheme("mero-sample", path: "link"), stateStore: CloudLinkStateStore(),
                authenticator: sheet)
            XCTFail("a decline must throw")
        } catch AccountError.linkDeclined(let message) {
            XCTAssertTrue(message.contains("declined"), message)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
