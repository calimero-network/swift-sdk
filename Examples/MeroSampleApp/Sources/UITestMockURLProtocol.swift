import Foundation
import MeroKit
import MeroKitUI

/// An in-app mock Cloud manager + relay, used only with `-uitest-mock`.
///
/// Answers the routes a Cloud sign-in walks — account challenge and relays,
/// the relay's attestation (a MOCK quote bound to the request's nonce),
/// `/auth/challenge` and `/auth/token` — plus the relay's query route for the
/// home screen's sample read. Deterministic, no network.
final class UITestMockURLProtocol: URLProtocol {
    static let relayURL = "https://relay.mock"
    private static let nodeSeed = Data(repeating: 0x42, count: 32)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Any

        switch path {
        case _ where path.hasPrefix("/api/cloud/accounts/") && path.hasSuffix("/challenge"):
            body = ["nonce": "uitest-nonce", "expires_at_ms": 4_000_000_000_000]
        case _ where path.hasPrefix("/api/cloud/accounts/") && path.hasSuffix("/relays"):
            body = ["relays": [["peer_id": "uitest", "relay_url": Self.relayURL, "fresh": true, "assigned": true]]]
        case "/admin-api/tee/attest":
            body = ["data": Self.attestation(nonceHex: Self.requestNonce(request))]
        case "/auth/challenge":
            body = ["data": ["challenge": String(repeating: "c4", count: 32)]]
        case "/auth/token", "/auth/refresh":
            body = ["data": ["access_token": "uitest-access", "refresh_token": "uitest-refresh"]]
        case _ where path.hasSuffix("/query"):
            body = ["data": ["returns": 42]]
        default:
            body = [String: Any]()
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestNonce(_ request: URLRequest) -> String {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["nonce"] as? String ?? ""
    }

    private static func attestation(nonceHex: String) -> [String: Any] {
        let key = (try? Ed25519.publicKey(seed: nodeSeed)) ?? Data(count: 32)
        let nonce = (try? Hex.decode(nonceHex, label: "nonce", bytes: 32)) ?? Data(count: 32)
        let quote = Data("MOCK_TDX_QUOTE_V1".utf8) + nonce + RelayNodeKey.keyBinding(key)
        return ["quoteB64": quote.base64EncodedString(), "boundPublicKey": Hex.encode(key)]
    }
}

/// Stands in for the wallet's web sheet in `-uitest-mock`: certifies the
/// device key named in the wallet URL with a fixed test root, so the app's real
/// verification runs. `-uitest-enrol-callback <url>` returns that URL instead.
struct UITestWallet: WebAuthenticating {
    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-uitest-enrol-callback"), i + 1 < args.count,
            let canned = URL(string: args[i + 1])
        {
            return canned
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        let root = Data(repeating: 0x5C, count: 32)
        let account = try DeviceCertificates.account(forRootPublicKey: Hex.encode(try Ed25519.publicKey(seed: root)))
        let device = try DeviceCertificates.mintDeviceId(account: account, nonce: Data(repeating: 0xA1, count: 16))
        let credential = try DeviceCertificates.certify(
            rootSeed: root, device: device, signPublicKey: item("enrol-device"), kemPublicKey: item("enrol-kem"))
        let fragment = "credential=\(credential)&account=\(account)&device=\(device)&state=\(item("state"))"
        guard let returned = URL(string: "\(item("callback-url"))#\(fragment)") else {
            throw AccountError.protocolViolation("bad callback")
        }
        return returned
    }
}
