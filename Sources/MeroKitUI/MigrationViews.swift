#if canImport(SwiftUI)
import MeroKit
import SwiftUI

/// Shown only while your own identity has entries below the target schema; one
/// button runs the one-tap `migrate_my_entries`, and the banner clears itself
/// once nothing is pending. (== mero-react `MigrationPendingBanner`.)
///
/// Identifiers: `migrationPendingBanner`, `migrationPendingButton`.
@MainActor
public struct MigrationPendingBanner: View {
    @EnvironmentObject private var client: MeroClient
    private let contextId: String
    private let message: String?
    private let onMigrated: (() -> Void)?

    /// - Parameters:
    ///   - message: your own prompt instead of the default.
    ///   - onMigrated: called once a convert leaves nothing pending.
    public init(contextId: String, message: String? = nil, onMigrated: (() -> Void)? = nil) {
        self.contextId = contextId
        self.message = message
        self.onMigrated = onMigrated
    }

    public var body: some View {
        MigrationPendingBannerContent(client: client, contextId: contextId, message: message, onMigrated: onMigrated)
            .id(contextId)
    }
}

@MainActor
struct MigrationPendingBannerContent: View {
    @Environment(\.meroTheme) private var theme
    @StateObject private var model: MyAuthoredMigrationModel
    private let message: String?
    private let onMigrated: (() -> Void)?

    init(client: MeroClient, contextId: String, message: String?, onMigrated: (() -> Void)?) {
        _model = StateObject(wrappedValue: MyAuthoredMigrationModel(client: client, contextId: contextId))
        self.message = message
        self.onMigrated = onMigrated
    }

    /// The default prompt for `count` entries.
    static func prompt(_ count: Int) -> String {
        "You have \(count) \(count == 1 ? "entry" : "entries") to re-sign after a recent upgrade."
    }

    var body: some View {
        if model.pending {
            HStack(spacing: 12) {
                Text(message ?? Self.prompt(model.pendingCount))
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(model.isLoading ? "Migrating…" : "Migrate my data") {
                    Task {
                        if let result = await model.authorize(), result.remaining == 0 { onMigrated?() }
                    }
                }
                .disabled(model.isLoading)
                .accessibilityIdentifier("migrationPendingButton")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: theme.radius).fill(theme.primary.opacity(0.15)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("migrationPendingBanner")
        }
    }
}

/// A namespace's migration rollup for an operator: the cohort counters,
/// members pending signature, and a row per member. Read-only.
/// (== mero-react `MigrationAdminPanel`.)
///
/// Identifiers: `migrationAdminPanel`, `migrationStatusError`,
/// `migrationFailedCount`, `membersPendingSignature`, `migrationMemberRow`.
@MainActor
public struct MigrationAdminPanel: View {
    @EnvironmentObject private var client: MeroClient
    private let namespaceId: String
    private let pollInterval: TimeInterval?

    /// - Parameter pollInterval: re-read cadence; with none, every
    ///   ``defaultMigrationPollInterval`` while the event stream is down.
    public init(namespaceId: String, pollInterval: TimeInterval? = nil) {
        self.namespaceId = namespaceId
        self.pollInterval = pollInterval
    }

    public var body: some View {
        MigrationAdminPanelContent(client: client, namespaceId: namespaceId, pollInterval: pollInterval)
            .id(namespaceId)
    }
}

@MainActor
struct MigrationAdminPanelContent: View {
    @StateObject private var model: MigrationStatusModel

    init(client: MeroClient, namespaceId: String, pollInterval: TimeInterval?) {
        _model = StateObject(
            wrappedValue: MigrationStatusModel(client: client, namespaceId: namespaceId, pollInterval: pollInterval))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.status, let rollup = model.rollup {
                if let error = model.error {
                    // Kept the last good rollup; say it may be stale.
                    Text("Could not refresh migration status: \(error.localizedDescription)")
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("migrationStatusError")
                }
                row("Target version", "\(status.targetVersion)")
                row("Migrated", "\(rollup.migrated)")
                row("In progress", "\(rollup.inProgress)")
                row("Unknown", "\(rollup.unknown)")
                row("Failed", "\(model.failed)").accessibilityIdentifier("migrationFailedCount")
                row("Total", "\(rollup.total)")
                row("All migrated", rollup.allMigrated ? "yes" : "no")
                row("Members pending signature", "\(model.membersPendingSignature)")
                    .accessibilityIdentifier("membersPendingSignature")
                Divider()
                ForEach(model.members, id: \.peer) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.peer).font(.system(.caption, design: .monospaced)).lineLimit(1)
                        Text(Self.describe(member)).font(.caption).foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("migrationMemberRow")
                }
            } else if let error = model.error {
                Text("Failed to load migration status: \(error.localizedDescription)")
            } else {
                Text("Loading migration status…")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("migrationAdminPanel")
        .onDisappear { model.stop() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    /// State, schema, pending count and failure, as the web table's columns.
    static func describe(_ member: MemberMigrationStatusEntry) -> String {
        let schema = member.report.map { "\($0.schemaVersion)" } ?? "—"
        let pending = member.report.map { "\($0.authoredRemaining)" } ?? "—"
        let reason = member.report?.migrationFailed?.rawValue ?? "—"
        return "\(member.state.rawValue) · schema \(schema) · pending \(pending) · \(reason)"
    }
}
#endif
