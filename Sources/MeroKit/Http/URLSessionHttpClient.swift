import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `x-auth-error` reasons that mean the whole token family is gone.
///
/// Refresh tokens are single-use (calimero-network/core#3083): presenting a
/// consumed refresh token is treated as theft and the server revokes the family.
/// Refreshing or retrying afterwards is pointless — the only way out is re-login.
private let terminalAuthErrors: Set<String> = ["token_reuse", "token_revoked"]

/// `URLSession`-backed ``HttpClient`` implementing the mero-js transport contract:
/// bearer-token injection, reactive 401→refresh (single-flight, retried once),
/// terminal `x-auth-error` handling, and backoff retry on network/5xx.
public final class URLSessionHttpClient: HttpClient {
    private let baseURL: URL
    private let session: URLSession
    private let defaultTimeout: TimeInterval
    private let hooks: TransportHooks
    private let refreshGate = RefreshGate()

    public init(
        baseURL: URL,
        timeout: TimeInterval = 10,
        hooks: TransportHooks = TransportHooks(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.defaultTimeout = timeout
        self.hooks = hooks
        self.session = session
    }

    // MARK: HttpClient

    public func send<T: Decodable>(_ req: HttpRequest) async throws -> T {
        let (data, head) = try await sendRaw(req)
        // Tolerate empty 2xx bodies (204 No Content, empty delete/resync).
        if data.isEmpty, let empty = Empty() as? T {
            return empty
        }
        do {
            return try MeroJSON.decode(T.self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw MeroError.decoding("status \(head.status): \(snippet)")
        }
    }

    public func sendVoid(_ req: HttpRequest) async throws {
        _ = try await sendRaw(req)
    }

    public func sendRaw(_ req: HttpRequest) async throws -> (Data, HeadResult) {
        try await withRetry { _ in
            try await self.attempt(req, allowRefresh: true)
        }
    }

    public func head(_ path: String, headers: [String: String]) async throws -> HeadResult {
        var req = HttpRequest(path: path, method: .head, headers: headers)
        req.timeout = defaultTimeout
        let (_, head) = try await sendRaw(req)
        return head
    }

    public func download(_ req: HttpRequest, to fileURL: URL) async throws -> HeadResult {
        // Stream the body to disk rather than buffering in RAM (memory-safe for large blobs).
        let urlRequest = buildURLRequest(req, bearer: await currentAuthToken())
        let (tempURL, response) = try await session.download(for: urlRequest)
        let http = response as? HTTPURLResponse
        let head = HeadResult(status: http?.statusCode ?? 0, headers: lowercasedHeaders(http))
        guard let status = http?.statusCode, (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: tempURL)
            let body = (try? Data(contentsOf: tempURL)).map { String(decoding: $0.prefix(65536), as: UTF8.self) }
            throw MeroError.http(
                HTTPError(
                    status: http?.statusCode ?? 0,
                    statusText: statusText(http?.statusCode ?? 0),
                    url: urlRequest.url?.absoluteString ?? req.path,
                    headers: head.headers,
                    bodyText: body
                ))
        }
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        return head
    }

    // MARK: - Core request path

    private func attempt(_ req: HttpRequest, allowRefresh: Bool) async throws -> (Data, HeadResult) {
        // Read the token once and keep it: a 401 has to be judged against what
        // this request actually sent, not against whatever the token is by the
        // time the response comes back.
        let presentedToken = await currentAuthToken()
        let urlRequest = buildURLRequest(req, bearer: presentedToken)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performFetch(urlRequest, body: req.body)
        } catch let urlErr as URLError {
            throw MeroError.network(urlErr.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MeroError.network("Non-HTTP response")
        }

        let headers = lowercasedHeaders(http)
        if (200..<300).contains(http.statusCode) {
            return (data, HeadResult(status: http.statusCode, headers: headers))
        }

        let bodyText = String(decoding: data.prefix(65536), as: UTF8.self)
        let httpError = HTTPError(
            status: http.statusCode,
            statusText: statusText(http.statusCode),
            url: urlRequest.url?.absoluteString ?? req.path,
            headers: headers,
            bodyText: bodyText.isEmpty ? nil : bodyText
        )

        let authError = headers["x-auth-error"]

        // Terminal: the token family is gone. Never refresh/retry — clear + surface.
        if let authError, terminalAuthErrors.contains(authError),
            http.statusCode == 401 || http.statusCode == 403
        {
            await refreshGate.invalidate()
            if let onAuthRevoked = hooks.onAuthRevoked {
                await onAuthRevoked()
            }
            throw MeroError.authRevoked(reason: authError, http: httpError)
        }

        // Reactive refresh on 401 token_expired — exactly once.
        if http.statusCode == 401,
            authError == "token_expired",
            allowRefresh,
            let refreshToken = hooks.refreshToken,
            !(req.body?.isStream ?? false)
        {
            let newToken = try await refreshGate.refresh(
                presented: presentedToken, using: refreshToken)
            guard let newToken, !newToken.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MeroError.http(httpError)
            }
            if let onTokenRefresh = hooks.onTokenRefresh {
                await onTokenRefresh(newToken)
            }
            // Retry once with the rotated token; no further refresh.
            return try await attempt(req, allowRefresh: false)
        }

        throw MeroError.http(httpError)
    }

    private func performFetch(_ request: URLRequest, body: HttpBody?) async throws -> (Data, URLResponse) {
        if case .file(let fileURL, _) = body {
            return try await session.upload(for: request, fromFile: fileURL)
        }
        return try await session.data(for: request)
    }

    /// The bearer to send, or nil for an unauthenticated request.
    /// Best-effort: a token-fetch failure sends none, like mero-js.
    private func currentAuthToken() async -> String? {
        guard let getAuthToken = hooks.getAuthToken,
            let token = await getAuthToken(),
            !token.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return token
    }

    private func buildURLRequest(_ req: HttpRequest, bearer: String?) -> URLRequest {
        var request = URLRequest(url: buildURL(req.path))
        request.httpMethod = req.method.rawValue
        request.timeoutInterval = req.timeout ?? defaultTimeout

        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        switch req.body {
        case .json(let data):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case .data(let data, let contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case .file(_, let contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // Body is streamed from disk by `session.upload(fromFile:)`.
        case .none:
            break
        }

        // Per-request headers win over defaults.
        for (key, value) in req.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func buildURL(_ path: String) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://"), let abs = URL(string: path) {
            return abs
        }
        let base = baseURL.absoluteString
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let joined = path.hasPrefix("/") ? "\(trimmedBase)\(path)" : "\(trimmedBase)/\(path)"
        return URL(string: joined) ?? baseURL
    }

    private func lowercasedHeaders(_ response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                out[k.lowercased()] = v
            }
        }
        return out
    }
}

private extension HttpBody {
    var isStream: Bool {
        if case .file = self { return true }
        return false
    }
}

/// Single-flight gate so concurrent 401s share one refresh call.
/// (== the `refreshTokenPromise` cache in mero-js `web-client.ts`.)
///
/// Sharing an *in-flight* refresh is only half of it. The gate clears when the
/// first waiter returns, so a request that read the old access token before the
/// rotation but whose 401 arrives after it finds the gate free and starts a
/// second refresh — see ``refresh(presented:using:)``.
private actor RefreshGate {
    private var inFlight: Task<String, Error>?
    /// The newest access token a refresh through this gate produced.
    private var latest: String?

    /// - Parameter presented: the access token the request that got the 401
    ///   actually sent, or nil if it sent none.
    func refresh(
        presented: String?,
        using refreshToken: @escaping @Sendable () async throws -> String
    ) async throws -> String? {
        // Already refreshed past the token this request presented, so its 401 is
        // stale news: the caller retries with `latest` and no second refresh
        // happens. Without this the request starts one of its own — which is
        // wasteful at best, and at worst hands a consumer that still holds the
        // older bundle a refresh token the server has already rotated away.
        if let presented, let latest, presented != latest {
            return latest
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await refreshToken() }
        inFlight = task
        defer { inFlight = nil }
        let token = try await task.value
        latest = token
        return token
    }

    func invalidate() {
        inFlight?.cancel()
        inFlight = nil
        // The family is gone; nothing this gate produced is worth retrying with.
        latest = nil
    }
}

/// Best-effort HTTP status reason phrases (URLSession doesn't expose `statusText`).
private func statusText(_ code: Int) -> String {
    HTTPURLResponse.localizedString(forStatusCode: code).capitalized
}
