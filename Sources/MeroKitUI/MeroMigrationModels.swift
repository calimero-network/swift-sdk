import Foundation
import MeroKit

// Upgrades, migrations, versions and blobs (mero-react `useMigrationEvents`,
// `useMigrationStatus`, `useAppVersion`, `useLatestVersion`,
// `useGroupAppVersion`, `useMyAuthoredMigration`, `useBlobUrl`).

/// The poll cadence ``MigrationStatusModel`` falls back to while the event
/// stream is down and no interval was named.
/// (== mero-react `DEFAULT_MIGRATION_POLL_INTERVAL_MS`, in seconds.)
public let defaultMigrationPollInterval: TimeInterval = 5

// MARK: - Migration events

/// A namespace's `GroupMigration` events, with ``isLive`` reporting whether
/// the subscribe actually succeeded. A non-admin never sees
/// `cascadeProgress`. (== mero-react `useMigrationEvents`.)
@MainActor
public final class MigrationEventsWatcher: ObservableObject {
    /// The stream is carrying frames: connected and subscribed.
    @Published public private(set) var isLive = false

    public let namespaceId: String?
    private weak var client: MeroClient?
    private let onEvent: @MainActor (GroupMigrationEvent) -> Void
    private var listen: Task<Void, Never>?
    private var watch: MeroSessionWatch?

    public init(
        client: MeroClient, namespaceId: String?, onEvent: @escaping @MainActor (GroupMigrationEvent) -> Void
    ) {
        self.client = client
        self.namespaceId = namespaceId
        self.onEvent = onEvent
        watch = MeroSessionWatch(client) { [weak self] in self?.start() }
        start()
    }

    public func start() {
        stop()
        guard let namespaceId, let events = try? client?.transport?.events else { return }
        let stream = events.migrationEvents()
        listen = Task { [weak self] in
            events.connect()
            do {
                try await events.subscribe(groupIds: [namespaceId])
                self?.isLive = true
            } catch {
                self?.isLive = false
            }
            do {
                for try await event in stream {
                    guard let self else { return }
                    self.onEvent(event)
                }
            } catch {
                self?.isLive = false
            }
        }
    }

    public func stop() {
        listen?.cancel()
        listen = nil
        isLive = false
    }
}

// MARK: - Migration status

/// A namespace's migration rollup. Re-read on every migration event (the
/// event says something moved; the read is the answer), and polled every
/// `pollInterval` — or, with none named, every ``defaultMigrationPollInterval``
/// for as long as the stream is down. (== mero-react `useMigrationStatus`.)
@MainActor
public final class MigrationStatusModel: ObservableObject {
    @Published public private(set) var status: MigrationStatus?
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    public let namespaceId: String?
    public let pollInterval: TimeInterval?
    private weak var client: MeroClient?
    private let sleep: MeroSleep
    private var sequence = 0
    private var poll: Task<Void, Never>?
    private var watch: MeroSessionWatch?
    /// The live stream; `nil` until started.
    public private(set) var events: MigrationEventsWatcher?

    public init(
        client: MeroClient, namespaceId: String?, pollInterval: TimeInterval? = nil,
        sleep: @escaping MeroSleep = meroTaskSleep, autostart: Bool = true
    ) {
        self.client = client
        self.namespaceId = namespaceId
        self.pollInterval = pollInterval
        self.sleep = sleep
        if autostart { start() }
    }

    public var rollup: MigrationStatusRollup? { status?.rollup }
    public var members: [MemberMigrationStatusEntry] { status?.members ?? [] }
    public var allMigrated: Bool { rollup?.allMigrated ?? false }
    public var membersPendingSignature: Int { rollup?.membersPendingSignature ?? 0 }
    /// Members whose migrate aborted.
    public var failed: Int { rollup?.failed ?? 0 }

    /// Read now, subscribe, and start polling.
    public func start() {
        guard let client else { return }
        events = MigrationEventsWatcher(client: client, namespaceId: namespaceId) { [weak self] _ in
            Task { await self?.refetch() }
        }
        watch = MeroSessionWatch(client) { [weak self] in
            Task { await self?.refetch() }
        }
        Task { await refetch() }
        startPolling()
    }

    public func stop() {
        poll?.cancel()
        poll = nil
        events?.stop()
    }

    private func startPolling() {
        poll?.cancel()
        let sleep = self.sleep
        let interval = pollInterval ?? defaultMigrationPollInterval
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(interval)
                guard let self, !Task.isCancelled else { return }
                // An explicit interval always polls; the default only while the stream is down.
                if self.pollInterval != nil || self.events?.isLive != true { await self.refetch() }
            }
        }
    }

    public func refetch() async {
        guard let admin = client?.admin, let namespaceId else {
            status = nil
            error = nil
            isLoading = false
            return
        }
        sequence += 1
        let seq = sequence
        isLoading = true
        error = nil
        do {
            let result = try await admin.getMigrationStatus(namespaceId)
            if seq == sequence { status = result }
        } catch {
            if seq == sequence { self.error = error }
        }
        if seq == sequence { isLoading = false }
    }
}

// MARK: - App version

/// The context's installed application version against the build the app
/// was shipped with: any difference is ``isStale`` ("reload to update").
/// Follows `AppVersionChanged` live. (== mero-react `useAppVersion`.)
@MainActor
public final class AppVersionModel: ObservableObject {
    @Published public private(set) var appVersion: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    public let contextId: String?
    public let expected: String?
    private weak var client: MeroClient?
    private var sequence = 0
    private var listen: Task<Void, Never>?
    private var watch: MeroSessionWatch?

    public init(client: MeroClient, contextId: String?, expected: String? = nil, autostart: Bool = true) {
        self.client = client
        self.contextId = contextId
        self.expected = expected
        if autostart {
            watch = MeroSessionWatch(client) { [weak self] in self?.start() }
            start()
        }
    }

    public var isStale: Bool {
        guard let appVersion, let expected else { return false }
        return appVersion != expected
    }

    public func start() {
        listen?.cancel()
        Task { await refetch() }
        guard let contextId, let events = try? client?.transport?.events else { return }
        let stream = events.appVersionChanges()
        events.connect()
        Task { _ = try? await events.subscribe(contextIds: [contextId]) }
        listen = Task { [weak self] in
            for await change in stream.ignoringErrors() where change.contextId == contextId {
                guard let self else { return }
                if let version = change.toVersion { self.apply(version) }
            }
        }
    }

    /// A live flip: wins over any read still in flight.
    func apply(_ version: String) {
        sequence += 1
        appVersion = version
    }

    public func refetch() async {
        guard let admin = client?.admin, let contextId else {
            appVersion = nil
            error = nil
            isLoading = false
            return
        }
        sequence += 1
        let seq = sequence
        isLoading = true
        error = nil
        do {
            let context = try await admin.getContext(contextId)
            if seq == sequence { appVersion = context.applicationVersion }
        } catch {
            if seq == sequence { self.error = error }
        }
        if seq == sequence { isLoading = false }
    }
}

// MARK: - Latest version

/// "Is a newer version published?": the registry's versions of a package
/// (newest first) against `currentVersion`. (== mero-react `useLatestVersion`.)
@MainActor
public final class LatestVersionModel: ObservableObject {
    @Published public private(set) var versions: [String] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    public let registryURL: String?
    public let packageName: String?
    public let currentVersion: String?
    private weak var client: MeroClient?
    private var sequence = 0

    public init(
        client: MeroClient, registryURL: String?, packageName: String?, currentVersion: String?,
        autostart: Bool = true
    ) {
        self.client = client
        self.registryURL = registryURL
        self.packageName = packageName
        self.currentVersion = currentVersion
        if autostart { Task { [weak self] in await self?.refetch() } }
    }

    /// The newest published version, or `nil`.
    public var latestVersion: String? { versions.first }

    /// The registry's newest is strictly greater than ``currentVersion``.
    public var updateAvailable: Bool {
        guard let latestVersion, let currentVersion else { return false }
        return compareSemver(latestVersion, currentVersion) > 0
    }

    public func refetch() async {
        sequence += 1
        let seq = sequence
        guard let client, client.admin != nil, let registryURL, let packageName else {
            versions = []
            error = nil
            isLoading = false
            return
        }
        let session = client.urlSession
        isLoading = true
        error = nil
        do {
            let bundles = try await ApplicationRegistry.bundles(
                registryURL: registryURL, package: packageName, session: session)
            let live = bundles.filter { !$0.yanked }.compactMap(\.appVersion)
            let sorted = Array(Set(live)).sorted { compareSemver($0, $1) > 0 }
            if seq == sequence { versions = sorted }
        } catch {
            if seq == sequence { self.error = error }
        }
        if seq == sequence { isLoading = false }
    }
}

// MARK: - Group app version

/// What a group runs, and whether a downloaded update is waiting to be
/// applied: ``pendingApply`` is true when the group's `appKey` is set,
/// non-zero, and not the blob installed for its application.
/// Re-read on any `AppVersionChanged`. (== mero-react `useGroupAppVersion`.)
@MainActor
public final class GroupAppVersionModel: ObservableObject {
    @Published public private(set) var version: String?
    @Published public private(set) var applicationId: String?
    @Published public private(set) var pendingApply = false
    /// Only from the group-info path (a subgroup); `nil` for a namespace.
    @Published public private(set) var activeUpgrade: GroupUpgradeStatus?
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    public let groupId: String?
    private weak var client: MeroClient?
    private var sequence = 0
    private var listen: Task<Void, Never>?
    private var watch: MeroSessionWatch?

    public init(client: MeroClient, groupId: String?, autostart: Bool = true) {
        self.client = client
        self.groupId = groupId
        if autostart {
            watch = MeroSessionWatch(client) { [weak self] in self?.start() }
            start()
        }
    }

    public func start() {
        listen?.cancel()
        Task { await refetch() }
        guard groupId != nil, let events = try? client?.transport?.events else { return }
        let stream = events.appVersionChanges()
        events.connect()
        listen = Task { [weak self] in
            for await _ in stream.ignoringErrors() {
                guard let self else { return }
                await self.refetch()
            }
        }
    }

    /// No pending signal: absent, or all zeros.
    static func isZeroAppKey(_ appKey: String?) -> Bool {
        guard let appKey, !appKey.isEmpty else { return true }
        return appKey.allSatisfy { $0 == "0" }
    }

    public func refetch() async {
        sequence += 1
        let seq = sequence
        guard let admin = client?.admin, let groupId else {
            clear()
            return
        }
        isLoading = true
        error = nil
        do {
            let resolved = try await Self.resolve(admin: admin, groupId: groupId)
            if seq == sequence {
                version = resolved.version
                applicationId = resolved.applicationId
                pendingApply = resolved.pendingApply
                activeUpgrade = resolved.activeUpgrade
            }
        } catch {
            if seq == sequence { self.error = error }
        }
        if seq == sequence { isLoading = false }
    }

    private func clear() {
        version = nil
        applicationId = nil
        pendingApply = false
        activeUpgrade = nil
        error = nil
        isLoading = false
    }

    struct Resolved: Sendable {
        var version: String?
        var applicationId: String?
        var pendingApply = false
        var activeUpgrade: GroupUpgradeStatus?
    }

    /// Namespace first (a top-level group is one), else the group's info,
    /// then the installed application's version and blob.
    static func resolve(admin: any AdminSurface, groupId: String) async throws -> Resolved {
        var resolved = Resolved()
        let appKey: String?
        if let namespace = try await admin.listNamespaces().first(where: { $0.namespaceId == groupId }) {
            appKey = namespace.appKey
            resolved.applicationId = namespace.targetApplicationId
        } else {
            let info = try await admin.getGroupInfo(groupId)
            appKey = info.appKey
            resolved.applicationId = info.targetApplicationId
            resolved.activeUpgrade = info.activeUpgrade
        }
        guard let applicationId = resolved.applicationId, !applicationId.isEmpty else { return resolved }
        let application = try await admin.getApplication(applicationId).application
        resolved.version = application?.version
        if let application, let appKey, !isZeroAppKey(appKey),
            let installed = InviteCodec.base58Decode(application.blob.bytecode)
        {
            resolved.pendingApply = appKey.lowercased() != Hex.encode(installed).lowercased()
        }
        return resolved
    }
}

// MARK: - My authored migration

/// Your own entries still below the target schema: ``pending`` once
/// `count_my_pending` says so, and ``authorize()`` runs the one-tap
/// `migrate_my_entries`. (== mero-react `useMyAuthoredMigration`.)
@MainActor
public final class MyAuthoredMigrationModel: AsyncMutation {
    @Published public private(set) var summary: MigrateMyEntriesSummary?
    @Published public private(set) var pendingCount = 0

    public let contextId: String?
    private weak var client: MeroClient?
    private var sequence = 0

    public init(client: MeroClient, contextId: String?, autostart: Bool = true) {
        self.client = client
        self.contextId = contextId
        super.init()
        if autostart { Task { [weak self] in await self?.refresh() } }
    }

    public var pending: Bool { pendingCount > 0 }

    /// Best-effort: a failed count keeps the previous value.
    public func refresh() async {
        guard let transport = client?.transport, let contextId else {
            pendingCount = 0
            return
        }
        sequence += 1
        let seq = sequence
        let rpc = transport.rpc
        if let count = try? await rpc.countMyPending(contextId), seq == sequence { pendingCount = count }
    }

    /// Convert your entries; the remaining count comes back with the result.
    @discardableResult
    public func authorize() async -> MigrateMyEntriesSummary? {
        guard let transport = client?.transport, let contextId else { return nil }
        let rpc = transport.rpc
        guard let result = await attempt({ try await rpc.migrateMyEntries(contextId) }) else { return nil }
        sequence += 1
        summary = result
        pendingCount = result.remaining
        return result
    }
}

// MARK: - Blob file

/// A temporary file removed when the last reference to it goes.
final class MeroTemporaryFile: @unchecked Sendable {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A blob's bytes, as `data` and as a local file (``fileURL``) for a
/// `QuickLook`, `ShareLink` or `AsyncImage(url:)`. The file is removed when the
/// input changes and when this model goes away, so it never outlives its use.
/// With `contextId` the node finds the blob among the context's peers (up to
/// core's ~30 s deadline, plus the transfer). (== mero-react `useBlobUrl`.)
@MainActor
public final class BlobFileModel: ObservableObject {
    @Published public private(set) var data: Data?
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    public let blobId: String?
    public let contextId: String?
    /// The file extension to give the file (`"png"`), so viewers can sniff it.
    public let fileExtension: String?
    private weak var client: MeroClient?
    private var file: MeroTemporaryFile?
    private var sequence = 0

    public init(
        client: MeroClient, blobId: String?, contextId: String? = nil, fileExtension: String? = nil,
        autostart: Bool = true
    ) {
        self.client = client
        self.blobId = blobId
        self.contextId = contextId
        self.fileExtension = fileExtension
        if autostart { Task { [weak self] in await self?.refetch() } }
    }

    /// The local file holding the blob, while it is current.
    public var fileURL: URL? { file?.url }

    /// The node answered 404: nobody holds the blob.
    public var notFound: Bool { isBlobNotFound(error) }

    public func refetch() async {
        sequence += 1
        let seq = sequence
        guard client?.admin != nil, let read = client?.readAdmin, let blobId else { return }
        isLoading = true
        error = nil
        do {
            let bytes = try await read.getBlob(blobId, contextId: contextId)
            // Checked before writing anything: a superseded answer leaves no file.
            guard seq == sequence else { return }
            var url = FileManager.default.temporaryDirectory.appendingPathComponent("mero-blob-\(UUID().uuidString)")
            if let fileExtension, !fileExtension.isEmpty { url.appendPathExtension(fileExtension) }
            try bytes.write(to: url, options: .atomic)
            file = MeroTemporaryFile(url: url)
            data = bytes
        } catch {
            if seq == sequence { self.error = error }
        }
        if seq == sequence { isLoading = false }
    }

    /// Drop the bytes and remove the file now.
    public func release() {
        sequence += 1
        file = nil
        data = nil
        error = nil
        isLoading = false
    }
}

extension AsyncThrowingStream where Failure == Error, Element: Sendable {
    /// The elements, ending quietly where the stream would throw.
    func ignoringErrors() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await element in self { continuation.yield(element) }
                } catch {
                    // Ended by a failure: finish quietly.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
