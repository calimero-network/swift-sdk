import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Local-node discovery. (== mero-js `nodeDiscovery.ts`.)
///
/// Calimero dev/desktop nodes expose a public, unauthenticated health endpoint
/// at `GET {nodeUrl}/admin-api/health` that returns
/// `{ "data": { "status": "alive" } }`. The common local layouts run on a
/// small, well-known set of ports, so instead of making the person type a URL
/// an app can probe those ports and offer whatever is actually running.
///
/// ```swift
/// let nodes = await NodeDiscovery.discoverLocalNodes()   // [http://localhost:2428, …]
/// ```
///
/// Cancel the calling task to stop a discovery: every in-flight probe is
/// cancelled with it and reads as not healthy.
public enum NodeDiscovery {
    /// Ports probed by default: the two-node dev stacks used across the
    /// Calimero apps (RPC + alt ports for node1 / node2).
    public static let defaultLocalNodePorts: [Int] = [2428, 2429, 2528, 2529]

    /// Per-probe timeout. A reachable local node answers almost at once and a
    /// closed port refuses fast, but a firewalled one can hang, so each probe
    /// is capped.
    public static let defaultProbeTimeout: TimeInterval = 2

    /// The canonical base URL of a local node on `port`: `http://localhost:<port>`.
    public static func localNodeURL(port: Int) -> URL {
        URL(string: "http://localhost:\(port)")!
    }

    /// Resolve an API `path` against a node `baseURL`. The base is given a
    /// trailing slash first, so a base that carries a path prefix
    /// (`http://host/node1`) keeps that segment instead of having it replaced
    /// by relative resolution. (== mero-js `nodeEndpoint`.)
    public static func nodeEndpoint(_ baseURL: URL, path: String) -> URL {
        let raw = baseURL.absoluteString
        let base = raw.hasSuffix("/") ? raw : raw + "/"
        guard let baseWithSlash = URL(string: base), let resolved = URL(string: path, relativeTo: baseWithSlash)
        else { return baseURL.appendingPathComponent(path) }
        return resolved.absoluteURL
    }

    /// Probe one node's health endpoint. `true` only when the node answers a
    /// 2xx and — when the body is JSON — reports a status of `alive`. A
    /// network error, a timeout, a non-2xx, or a cancelled task is `false`;
    /// this never throws. (== mero-js `probeNodeHealth`.)
    ///
    /// A 2xx whose body is not JSON, or names no status, is alive; a status
    /// that is present but not `alive` (an explicit `null` included) is not.
    public static func probeNodeHealth(
        _ baseURL: URL, timeout: TimeInterval = NodeDiscovery.defaultProbeTimeout, session: URLSession = .shared
    ) async -> Bool {
        if Task.isCancelled { return false }
        let url = nodeEndpoint(baseURL, path: "admin-api/health")
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = max(timeout, 0.001)
                guard let result = try? await session.data(for: request) else { return false }
                let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                return isHealthy(status: status, body: result.0)
            }
            group.addTask {
                // The whole probe's deadline: URLRequest's timeout only bounds idle time.
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first.flatMap { $0 } ?? false
        }
    }

    /// Probe `ports` on localhost in parallel and return the base URLs that
    /// answered healthy, in the order of `ports`. Empty when nothing local is
    /// running. (== mero-js `discoverLocalNodes`.)
    public static func discoverLocalNodes(
        ports: [Int] = NodeDiscovery.defaultLocalNodePorts,
        timeout: TimeInterval = NodeDiscovery.defaultProbeTimeout,
        session: URLSession = .shared
    ) async -> [URL] {
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, port) in ports.enumerated() {
                group.addTask {
                    let url = localNodeURL(port: port)
                    let healthy = await probeNodeHealth(url, timeout: timeout, session: session)
                    return (index, healthy ? url : nil)
                }
            }
            var found: [(Int, URL)] = []
            for await (index, url) in group {
                if let url { found.append((index, url)) }
            }
            return found.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// Whether a health response means the node is alive.
    static func isHealthy(status: Int, body: Data) -> Bool {
        guard (200..<300).contains(status) else { return false }
        guard case .object(let obj)? = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return true  // non-JSON (or non-object) 2xx: the status line is enough
        }
        var reported: JSONValue?
        if case .object(let data)? = obj["data"], let inner = data["status"] {
            reported = inner
        } else {
            reported = obj["status"]
        }
        guard let reported else { return true }
        if case .string(let value) = reported { return value.lowercased() == "alive" }
        return false
    }
}
