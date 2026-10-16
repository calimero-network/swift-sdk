import Foundation
import MeroKit

#if canImport(Combine)
import Combine
#endif

/// One read: `data`, `isLoading` and `error`, with a latest-request-wins
/// guard. Port of mero-react's `useAsyncResource`, the shape every read hook
/// is built on.
///
/// - A `nil` fetcher is a disabled read (missing input): `data` goes back to
///   `initial` and nothing is fetched.
/// - Changing the fetcher (``setFetcher(_:)``) drops the previous input's data
///   and error at once and invalidates any request still in flight, so a slow
///   earlier answer can never overwrite a newer one.
/// - ``bind(to:_:)`` re-derives the fetcher whenever the client's session
///   changes — mero-react's dependency on `admin`.
@MainActor
public final class AsyncResource<Value: Sendable>: ObservableObject {
    public typealias Fetcher = @Sendable () async throws -> Value

    @Published public private(set) var data: Value
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    private let initial: Value
    private var fetcher: Fetcher?
    private var sequence = 0
    private var task: Task<Void, Never>?
    #if canImport(Combine)
    private var binding: AnyCancellable?
    #endif

    /// - Parameter autoload: fetch now (`true`, as a hook does on mount).
    public init(initial: Value, fetcher: Fetcher? = nil, autoload: Bool = true) {
        self.initial = initial
        self.data = initial
        self.fetcher = fetcher
        if autoload, fetcher != nil { start() }
    }

    /// Whether a fetcher is set (the read is enabled).
    public var isEnabled: Bool { fetcher != nil }

    /// Replace what is read (new input): reset to `initial`, invalidate any
    /// request in flight, and fetch again.
    public func setFetcher(_ fetcher: Fetcher?) {
        self.fetcher = fetcher
        sequence += 1
        data = initial
        error = nil
        isLoading = false
        start()
    }

    /// Fetch again in the background.
    public func start() {
        task?.cancel()
        task = Task { [weak self] in await self?.refetch() }
    }

    /// Fetch again, and return once the answer (or the failure) is published.
    /// Superseded by a newer request, it publishes nothing.
    public func refetch() async {
        sequence += 1
        let seq = sequence
        guard let fetcher else {
            data = initial
            error = nil
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        do {
            let value = try await fetcher()
            if seq == sequence { data = value }
        } catch {
            if seq == sequence { self.error = error }
        }
        if seq == sequence { isLoading = false }
    }

    /// Set `data` directly (a write that knows the new value), invalidating
    /// any read in flight.
    public func override(_ value: Value) {
        sequence += 1
        data = value
        error = nil
        isLoading = false
    }

    #if canImport(Combine)
    /// Re-derive the fetcher from `client` now and on every session change.
    @discardableResult
    public func bind(
        to client: MeroClient, _ make: @escaping @MainActor @Sendable (MeroClient) -> Fetcher?
    ) -> Self {
        setFetcher(make(client))
        binding = client.$sessionRevision.dropFirst().sink { [weak self, weak client] _ in
            // `$sessionRevision` fires before the change lands; read after it.
            Task { @MainActor [weak self, weak client] in
                guard let self, let client else { return }
                self.setFetcher(make(client))
            }
        }
        return self
    }
    #endif
}

/// One write: `isLoading`, `error` and `failure`. Port of mero-react's
/// `useAsyncMutation`, which every write hook is built on.
///
/// ``run(_:)`` resolves `nil` on failure (after recording it) unless
/// ``throwOnError`` is set, in which case it rethrows the original error.
@MainActor
open class AsyncMutation: ObservableObject {
    @Published public internal(set) var isLoading = false
    @Published public internal(set) var error: Error?
    /// What kind of refusal the last failure was, and whether trying again
    /// later could work.
    @Published public internal(set) var failure: ClassifiedError?

    /// Rethrow failures from ``run(_:)`` instead of resolving `nil`.
    /// (== mero-react `MutationOptions.throwOnError`.)
    public let throwOnError: Bool

    public init(throwOnError: Bool = false) {
        self.throwOnError = throwOnError
    }

    /// Run `action`, recording its failure.
    @discardableResult
    public func run<T: Sendable>(_ action: @Sendable () async throws -> T) async throws -> T? {
        isLoading = true
        error = nil
        failure = nil
        defer { isLoading = false }
        do {
            return try await action()
        } catch {
            self.error = error
            failure = classifyError(error)
            if throwOnError { throw error }
            return nil
        }
    }

    /// ``run(_:)`` that never throws, whatever ``throwOnError`` says.
    @discardableResult
    public func attempt<T: Sendable>(_ action: @Sendable () async throws -> T) async -> T? {
        isLoading = true
        error = nil
        failure = nil
        defer { isLoading = false }
        do {
            return try await action()
        } catch {
            self.error = error
            failure = classifyError(error)
            return nil
        }
    }

    /// Record a refusal that never reached the network ("not connected").
    public func fail(_ error: Error) {
        self.error = error
        failure = classifyError(error)
    }
}

/// The error a hook reports with no client to send through.
public struct NotConnectedError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String = "Not connected") {
        self.message = message
    }

    public var errorDescription: String? { message }

    /// The account is signed in but no relay serves it yet: an invitation is
    /// the cure, not a new login.
    public static let noRelay = NotConnectedError(
        "No relay for this account yet, so there is nowhere to send this write. Redeeming an invitation admits the "
            + "account to a namespace and gives it a relay; reads and events resume with it.")
}
