import Foundation
import MeroKit
import XCTest

/// End-to-end against a real development cluster (`merod local`, mock
/// attestation). Skipped unless `MERO_E2E_NODE_URL` names one of its nodes,
/// e.g. `http://127.0.0.1:2501`. With `MERO_E2E_BUNDLE` (a dev `.wasm` that
/// exports `set`/`get`, like core's kv-store) it also creates an app and
/// calls it.
final class RealNodeE2ETests: XCTestCase {
    private var nodeURL: String {
        get throws {
            guard let url = ProcessInfo.processInfo.environment["MERO_E2E_NODE_URL"], !url.isEmpty else {
                throw XCTSkip("MERO_E2E_NODE_URL is not set")
            }
            return url
        }
    }

    func testSignsUpCreatesAnOrgAndCallsAnApp() async throws {
        let client = CalimeroClient(CalimeroClientOptions(baseUrl: try nodeURL, policy: .development))
        let session = try await client.signUp(SoftPasskey(), name: "swift-e2e")
        XCTAssertFalse(session.accountId.isEmpty)
        let org = try await client.createOrg("swift-e2e")
        let orgs = try await client.me().orgs
        XCTAssertTrue(orgs.contains { $0.orgId == org })
        try await client.refresh()

        guard let path = ProcessInfo.processInfo.environment["MERO_E2E_BUNDLE"] else { return }
        let bundle = try await client.uploadBundle(try Data(contentsOf: URL(fileURLWithPath: path)))
        let app = try await client.createApp("kv", bundle: .bundle(bundle), org: org, initArgs: [:])
        _ = try await client.call(app, "set", ["key": "a", "value": "1"])
        let read = try await client.view(app, "get", ["key": "a"])
        XCTAssertEqual(read.result, "1")
    }
}
