import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Sealing a delegated session's calls to a hosted relay. Port of mero-js
// `relayTransportFetch` / `forgetRelaySealing` (`src/account/session.ts`).
//
// Everything a delegated session sends a hosted relay is sealed to the
// relay's attested TD (``SealedTransport``), so TLS that ends at the relay's
// ingress, and whoever holds its certificate, reads none of it: not the
// login, not the token, not a query or its result, not an event.
//
// A relay whose node leaves auth to its proxy, and has no
// `[server.sealed] forward_auth`, cannot guard a logged-in route inside the
// envelope and answers `403 sealed_route_unguarded` from inside it. Only then
// does a request go out plain, as it always did before sealing: that answer
// is sealed under the session, so nobody on the way can forge it to force
// the downgrade. Anything else that goes wrong — an attestation refused, a
// relay that does not answer — fails the request; it never falls back.

extension DelegatedAccounts {
    /// The `URLSession` a delegated session uses for `relayURL`: sealed to its
    /// attested TD, one per relay so its sealed session is shared.
    /// `env.urlSession` itself for a loopback relay (a dev rig answering mock
    /// quotes), or when ``DelegatedEnvironment/sealRelays`` is off.
    /// (== mero-js `relayTransportFetch`.)
    ///
    /// The relay is attested with the ``DcapRelayKeyVerifier`` of
    /// `env.relayKeyVerifier` when it is one, and otherwise with its
    /// signed-release verifier (`DcapRelayKeyVerifier.signedReleaseVerifier`).
    public static func relayTransportSession(_ relayURL: String, env: DelegatedEnvironment) -> URLSession {
        let relay = relayOrigin(relayURL)
        guard env.sealRelays, !RelayNodeKey.isLoopback(relay), let base = URL(string: relay) else {
            return env.urlSession
        }
        let key = "\(relay)#\(ObjectIdentifier(env.urlSession).hashValue)"
        let sealed = RelaySealing.shared.session(for: key, base: base) {
            let verifier: any TransportQuoteVerifier =
                (env.relayKeyVerifier as? DcapRelayKeyVerifier)?.verifierFor(relay)
                ?? DcapRelayKeyVerifier.signedReleaseVerifier(relayURL: relay, session: env.urlSession)
            let transport = try SealedTransport.attested(
                baseURL: base, verifier: verifier, applicationId: nil, applicationHash: nil, session: env.urlSession,
                unguardedFallback: true)
            return transport.urlSession()
        }
        return sealed ?? env.urlSession
    }

    /// Forget every relay's sealed transport, so the next call attests again.
    /// (== mero-js `forgetRelaySealing`.)
    public static func forgetRelaySealing() {
        RelaySealing.shared.clear()
    }
}

/// The sealed sessions of the relays this process talks to.
final class RelaySealing: @unchecked Sendable {
    static let shared = RelaySealing()

    private struct RelaySealingEntry {
        let base: URL
        let session: URLSession
    }

    private let lock = NSLock()
    private var entries: [String: RelaySealingEntry] = [:]

    /// The session under `key`, made by `make` the first time; `nil` when it cannot be made.
    func session(for key: String, base: URL, make: () throws -> URLSession) -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        if let found = entries[key] { return found.session }
        guard let made = try? make() else { return nil }
        entries[key] = RelaySealingEntry(base: base, session: made)
        return made
    }

    func clear() {
        lock.lock()
        let all = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        for entry in all {
            entry.session.invalidateAndCancel()
            SealedURLProtocol.unregister(baseURL: entry.base)
        }
    }
}
