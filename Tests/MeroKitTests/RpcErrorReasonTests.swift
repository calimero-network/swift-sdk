import Foundation
import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A contract that returns an error, or panics, answers
/// `{"type":"FunctionCallError","data":"<reason>"}` with no `message`: the
/// reason an app wants to show is in `data`. It has to be one property away.
final class RpcErrorReasonTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func serve(_ json: String, status: Int = 200) {
        MockURLProtocol.setHandler { _ in
            .init(status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        }
    }

    private func rpcError(_ json: String) async -> RpcError? {
        serve(json)
        let rpc = RpcClient(
            http: URLSessionHttpClient(
                baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession()))
        do {
            let _: Int = try await rpc.execute(contextId: "ctx", method: "transfer")
            XCTFail("expected an error")
        } catch MeroError.rpc(let error) {
            return error
        } catch {
            XCTFail("wrong error: \(error)")
        }
        return nil
    }

    /// The shape core sends (`ExecutionError::FunctionCallError(String)`).
    func testAContractErrorCarriesItsReason() async throws {
        let error = try await XCTUnwrapAsync(
            await rpcError(
                #"{"jsonrpc":"2.0","id":1,"error":{"type":"FunctionCallError","data":"insufficient balance"}}"#))
        XCTAssertTrue(error.isFunctionCallError)
        XCTAssertEqual(error.reason, "insufficient balance")
        XCTAssertEqual(error.message, "FunctionCallError: insufficient balance")
        XCTAssertEqual(MeroError.rpc(error).callFailureReason, "insufficient balance")
    }

    /// A nested `{type, data}` (core's tagged-enum shape) is not reduced to
    /// the bare type.
    func testANestedReasonIsUnwrapped() async throws {
        let error = try await XCTUnwrapAsync(
            await rpcError(
                """
                {"jsonrpc":"2.0","id":1,"error":{"type":"FunctionCallError",\
                "data":{"type":"HostError","data":{"type":"Panic","data":{"message":"index out of bounds"}}}}}
                """))
        XCTAssertNotEqual(error.message, "FunctionCallError")
        XCTAssertEqual(error.reason, "HostError: Panic: index out of bounds")
        XCTAssertEqual(error.message, "FunctionCallError: HostError: Panic: index out of bounds")
    }

    func testANodeMessageIsKeptAndTheReasonStillReadable() async throws {
        let error = try await XCTUnwrapAsync(
            await rpcError(
                #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"boom","type":"FunctionCallError","data":"why"}}"#
            ))
        XCTAssertEqual(error.message, "boom")
        XCTAssertEqual(error.reason, "why")
    }

    func testWithNoDataTheReasonIsTheMessage() {
        let error = RpcError(code: -32000, message: "method not found")
        XCTAssertEqual(error.reason, "method not found")
        XCTAssertFalse(error.isFunctionCallError)
    }

    /// `/query` and `/intents` refuse a failed method with a `400` carrying
    /// the same `type`/`data` pair.
    func testAnHttpRefusalCarriesTheReasonToo() {
        let http = HTTPError(
            status: 400, statusText: "Bad Request", url: "https://node.test/admin-api/contexts/c/query",
            headers: [:],
            bodyText: #"{"error":"method failed","type":"FunctionCallError","data":"panicked: nope"}"#)
        XCTAssertEqual(MeroError.http(http).callFailureReason, "panicked: nope")
        let bare = HTTPError(
            status: 400, statusText: "Bad Request", url: "u", headers: [:], bodyText: #"{"error":"bad input"}"#)
        XCTAssertEqual(MeroError.http(bare).callFailureReason, "bad input")
        XCTAssertNil(MeroError.network("offline").callFailureReason)
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async -> T?) async throws -> T {
    let resolved = await value()
    return try XCTUnwrap(resolved)
}
