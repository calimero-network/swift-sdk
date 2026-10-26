import XCTest

@testable import MeroKit

/// The registry publishes bundles ahead of the nodes that run them: on
/// 2026-10-25 every app moved to `minRuntimeVersion: 0.12.0-rc.1` while CI's
/// node was on 0.11.0, and installing "the newest version" answered 500.
final class ApplicationRegistryRuntimeTests: XCTestCase {
    typealias Bundle = ApplicationRegistry.Bundle

    func testCompareVersionsOrdersPrereleasesBeforeTheirRelease() {
        let ordered = [
            "0.11.0-rc.9", "0.11.0-rc.10", "0.11.0-rc.90", "0.11.0", "0.11.1", "0.12.0-alpha", "0.12.0-rc.1",
            "0.12.0-rc.1.1", "0.12.0-rc.2", "0.12.0", "1.0.0",
        ]
        for (i, a) in ordered.enumerated() {
            for (j, b) in ordered.enumerated() {
                let c = ApplicationRegistry.compareVersions(a, b)
                XCTAssertEqual(c.signum(), (i - j).signum(), "\(a) vs \(b)")
            }
        }
    }

    func testCompareVersionsTreatsMissingPartsAsZeroAndIgnoresBuild() {
        XCTAssertEqual(ApplicationRegistry.compareVersions("1.2", "1.2.0"), 0)
        XCTAssertEqual(ApplicationRegistry.compareVersions("v1.2.0", "1.2.0"), 0)
        XCTAssertEqual(ApplicationRegistry.compareVersions("1.2.0+abc", "1.2.0+def"), 0)
        XCTAssertLessThan(ApplicationRegistry.compareVersions("0.0.9", "0.0.41"), 0)
        XCTAssertLessThan(ApplicationRegistry.compareVersions("3.1.9", "3.1.46"), 0)
    }

    func testSupportsComparesTheMinimumAgainstTheRuntime() {
        XCTAssertFalse(ApplicationRegistry.supports(runtimeVersion: "0.11.0", minRuntimeVersion: "0.12.0-rc.1"))
        XCTAssertFalse(ApplicationRegistry.supports(runtimeVersion: "0.11.0", minRuntimeVersion: "0.11.1"))
        XCTAssertTrue(ApplicationRegistry.supports(runtimeVersion: "0.11.0", minRuntimeVersion: "0.11.0-rc.90"))
        XCTAssertTrue(ApplicationRegistry.supports(runtimeVersion: "0.11.0", minRuntimeVersion: "0.11.0"))
        XCTAssertTrue(ApplicationRegistry.supports(runtimeVersion: "0.12.0", minRuntimeVersion: "0.12.0-rc.1"))
        XCTAssertTrue(ApplicationRegistry.supports(runtimeVersion: nil, minRuntimeVersion: "9.0.0"))
        XCTAssertTrue(ApplicationRegistry.supports(runtimeVersion: "0.11.0", minRuntimeVersion: nil))
    }

    func testSelectLatestHonoursTheRuntimeOnlyWhenGiven() {
        let bundles: [Bundle] = [
            .init(appVersion: "3.1.46", minRuntimeVersion: "0.12.0-rc.1"),
            .init(appVersion: "3.1.45", minRuntimeVersion: "0.11.1"),
            .init(appVersion: "3.1.44", minRuntimeVersion: "0.11.0-rc.90"),
            .init(appVersion: "3.1.50", yanked: true, minRuntimeVersion: "0.11.0"),
        ]
        XCTAssertEqual(ApplicationRegistry.selectLatest(bundles)?.appVersion, "3.1.46")
        XCTAssertEqual(ApplicationRegistry.selectLatest(bundles, runtimeVersion: "0.11.0")?.appVersion, "3.1.44")
        XCTAssertEqual(ApplicationRegistry.selectLatest(bundles, runtimeVersion: "0.11.1")?.appVersion, "3.1.45")
        XCTAssertNil(ApplicationRegistry.selectLatest(bundles, runtimeVersion: "0.10.0"))
    }

    func testBundleReadsEitherSpellingOfTheMinimum() throws {
        let camel = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"appVersion":"1.0.0","minRuntimeVersion":"0.12.0-rc.1"}"#.utf8))
        let snake = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"appVersion":"1.0.0","min_runtime_version":"0.11.1","yanked":true}"#.utf8))
        XCTAssertEqual(Bundle(json: camel).minRuntimeVersion, "0.12.0-rc.1")
        XCTAssertEqual(Bundle(json: snake).minRuntimeVersion, "0.11.1")
        XCTAssertTrue(Bundle(json: snake).yanked)
    }

    func testRuntimeVersionIsReadFromTheNodesRefusal() {
        let refusal = "bundle requires runtime version 0.12.0-rc.1 but current runtime is 0.11.0"
        XCTAssertEqual(ApplicationRegistry.runtimeVersion(fromInstallError: refusal), "0.11.0")
        XCTAssertEqual(
            ApplicationRegistry.runtimeVersion(fromInstallError: #"{"error":"… current runtime is 0.11.0-rc.89."}"#),
            "0.11.0-rc.89")
        XCTAssertNil(ApplicationRegistry.runtimeVersion(fromInstallError: "HTTP 500 Internal Server Error"))

        let http = MeroError.http(
            HTTPError(
                status: 500, statusText: "Internal Server Error", url: "/admin-api/install-application",
                headers: [:], bodyText: refusal))
        XCTAssertEqual(AdminApi.runtimeVersion(refusedBy: http), "0.11.0")
        XCTAssertNil(AdminApi.runtimeVersion(refusedBy: MeroError.network("offline")))
    }

    func testNewestCompatibleWalksNewestFirstSkippingYankedAndChecked() async throws {
        let minimums = [
            "0.0.72": "0.12.0-rc.1", "0.0.71": "0.11.1", "0.0.70": "0.11.0-rc.90", "0.0.69": "0.11.0-rc.90",
            "0.0.9": "0.1.0",
        ]
        var read: [String] = []
        let picked = try await ApplicationRegistry.newestCompatible(
            versions: ["0.0.9", "0.0.72", "0.0.71", "0.0.70", "0.0.69"], yanked: ["0.0.70"], skipping: ["0.0.72"],
            runtimeVersion: "0.11.0"
        ) { version in
            read.append(version)
            return Bundle(appVersion: version, minRuntimeVersion: minimums[version])
        }
        XCTAssertEqual(picked, "0.0.69")
        XCTAssertEqual(read, ["0.0.71", "0.0.69"])
    }

    func testNewestCompatibleStopsAtTheLimit() async throws {
        var reads = 0
        let picked = try await ApplicationRegistry.newestCompatible(
            versions: (1...10).map { "1.0.\($0)" }, yanked: [], skipping: [], runtimeVersion: "0.1.0", limit: 3
        ) { version in
            reads += 1
            return Bundle(appVersion: version, minRuntimeVersion: "9.0.0")
        }
        XCTAssertNil(picked)
        XCTAssertEqual(reads, 3)
    }
}
