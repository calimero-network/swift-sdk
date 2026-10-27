import Foundation
import MeroKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The login dialog's tabs. (== mero-react `LoginModalTab`.)
public enum LoginModalTab: String, Sendable, CaseIterable, Identifiable {
    /// A node: discovery plus a manual URL.
    case node
    /// A Calimero account, through the wallet.
    case cloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .node: return "Node"
        case .cloud: return "Cloud"
        }
    }
}

/// The Node tab's state: local nodes found on the well-known ports, or a URL
/// typed in. A discovered node already answered a health check and connects
/// at once; a typed one is checked first (`admin-api/is-authed` answering
/// 2xx or 401). Port of mero-react `LoginModal`'s node section.
@MainActor
public final class NodeLoginModel: ObservableObject {
    /// Base URLs that answered healthy, in port order.
    @Published public private(set) var discovered: [String] = []
    @Published public private(set) var isDiscovering = false
    /// The chosen discovered node, or `nil` for the manual URL.
    @Published public var selected: String?
    /// The URL typed in.
    @Published public var customURL: String = ""
    @Published public private(set) var isChecking = false
    @Published public private(set) var error: String?

    public let ports: [Int]
    private let session: URLSession
    private var scan: Task<Void, Never>?

    public init(ports: [Int] = NodeDiscovery.defaultLocalNodePorts, session: URLSession = .shared) {
        self.ports = ports
        self.session = session
    }

    /// Probe the local ports again. The first node found is selected; with
    /// none, the manual URL.
    public func rescan() {
        scan?.cancel()
        discovered = []
        error = nil
        isDiscovering = true
        let ports = ports
        let session = session
        scan = Task { [weak self] in
            let found = await NodeDiscovery.discoverLocalNodes(ports: ports, session: session)
            guard let self, !Task.isCancelled else { return }
            let urls = found.map { Self.trimmed($0.absoluteString) }
            self.discovered = urls
            self.selected = urls.first
            self.isDiscovering = false
        }
    }

    public func stop() {
        scan?.cancel()
        isDiscovering = false
    }

    /// Whether Connect can fire.
    public var canConnect: Bool {
        guard !isChecking, !isDiscovering else { return false }
        return selected != nil || Self.isValidNodeURL(customURL)
    }

    /// Whether the chosen node would be reached over plain http across the
    /// network: not https, and not a local address (``TransportSecurity``).
    /// A password or token would then travel in the clear, so
    /// ``resolveTarget()`` refuses it; show a warning while it is `true`.
    public var isInsecure: Bool {
        guard !TransportSecurity.allowInsecureHTTP else { return false }
        if let selected { return !TransportSecurity.isSecureOrLocal(selected) }
        guard Self.isValidNodeURL(customURL) else { return false }
        return !TransportSecurity.isSecureOrLocal(Self.normalized(customURL))
    }

    /// The node to connect to, checked: a discovered one as is; a typed one
    /// once it answers. `nil` (with ``error`` set) when it does not, or when
    /// it ``isInsecure``.
    public func resolveTarget() async -> String? {
        if isInsecure {
            error = MeroClient.insecureNodeURLMessage
            return nil
        }
        if let selected { return selected }
        guard Self.isValidNodeURL(customURL), let base = URL(string: Self.normalized(customURL)) else { return nil }
        isChecking = true
        error = nil
        defer { isChecking = false }
        var request = URLRequest(url: NodeDiscovery.nodeEndpoint(base, path: "admin-api/is-authed"))
        request.timeoutInterval = 10
        let status = (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
        if let status, (200..<300).contains(status) || status == 401 { return Self.trimmed(base.absoluteString) }
        error = "Failed to connect. Please check the URL and try again."
        return nil
    }

    /// `https://` added when no scheme is given. Another scheme (`ftp://…`)
    /// is kept, so validation refuses it rather than reading `ftp` as a host.
    static func normalized(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    }

    static func trimmed(_ url: String) -> String {
        var url = url
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// An http(s) URL naming `localhost`, an IPv4 address or a domain name.
    /// (== mero-react `isValidUrl`.)
    public static func isValidNodeURL(_ input: String) -> Bool {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty,
            let components = URLComponents(string: normalized(input)),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return false }
        if host == "localhost" { return true }
        if host.range(of: #"^(\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil {
            return host.split(separator: ".").allSatisfy { (Int($0) ?? 256) <= 255 }
        }
        let label = "[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
        return host.range(of: "^\(label)(\\.\(label))*$", options: .regularExpression) != nil
    }

    /// `localhost:2428` for a node's label.
    public static func display(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return trimmed(text)
    }
}
