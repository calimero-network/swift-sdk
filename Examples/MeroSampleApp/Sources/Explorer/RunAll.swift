import Foundation
import MeroKit
import SwiftUI
import UIKit

// MARK: - The plan

/// One step of "Run all": an explorer operation, the inputs to run it with, and
/// what to remember from its answer for the steps after it.
struct RunStep: Sendable {
    let opId: String
    /// Inputs, built from what earlier steps found (ids, versions).
    let inputs: @Sendable ([String: String]) -> [String: String]
    /// Ids to remember from the output, as fixture key → JSON key.
    var captures: [String: String] = [:]
    /// An extra check on the output; returns why it failed, or nil.
    var expect: (@Sendable (String) -> String?)?
    /// Fixture keys this step needs; it is skipped when one is missing.
    var needs: [String] = []
}

/// What "Run all" does, in order:
///
/// 1. **Reads** — every operation that takes no input.
/// 2. **Lifecycle** — a throwaway kv-store app from the registry, a namespace,
///    a group, a context, RPC writes and reads, aliases, a blob and an invite,
///    each step fed the ids the earlier ones returned; then it deletes what it
///    made, so the node is left as it was.
/// 3. **Skipped** — everything else, with the reason (it would sign you out,
///    needs a second node, is Cloud-only, …).
///
/// Only a session signed in to a node directly runs the lifecycle; a Cloud
/// session runs the reads through the relay and skips the rest.
enum RunAllPlan {
    static let package = "com.calimero.kv-store"
    static let registry = "https://apps.calimero.network"

    static func lifecycle(stamp: String) -> [RunStep] {
        let alias = "run-all-\(stamp)"
        return [
            RunStep(
                opId: "pkg.regVersions", inputs: { _ in ["registryUrl": registry, "packageName": package] },
                captures: ["version": "$first"]),
            RunStep(
                opId: "pkg.semver", inputs: { _ in ["a": "1.2.0", "b": "1.10.0"] },
                expect: { output in
                    // "compareSemver(a, b) = n": n < 0 when a sorts first.
                    let n = output.split(separator: "=").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    return (n ?? 0) < 0 ? nil : "1.2.0 should sort before 1.10.0"
                }),
            RunStep(
                opId: "pkg.install", inputs: { f in ["packageName": package, "version": f["version"] ?? ""] },
                captures: ["appId": "applicationId"], needs: ["version"]),
            RunStep(opId: "app.get", inputs: { f in ["appId": f["appId"] ?? ""] }, needs: ["appId"]),
            RunStep(opId: "app.versions", inputs: { f in ["appId": f["appId"] ?? ""] }, needs: ["appId"]),
            RunStep(opId: "app.abi", inputs: { f in ["appId": f["appId"] ?? ""] }, needs: ["appId"]),
            RunStep(opId: "pkg.versions", inputs: { _ in ["packageName": package] }),
            RunStep(opId: "pkg.latest", inputs: { _ in ["packageName": package] }),
            RunStep(
                opId: "ns.create",
                inputs: { f in ["body": #"{"applicationId":"\#(f["appId"] ?? "")","name":"\#(alias)"}"#] },
                captures: ["namespaceId": "namespaceId"], needs: ["appId"]),
            RunStep(opId: "ns.get", inputs: ns, needs: ["namespaceId"]),
            RunStep(opId: "ns.groups", inputs: ns, needs: ["namespaceId"]),
            RunStep(opId: "ns.migStatus", inputs: ns, needs: ["namespaceId"]),
            RunStep(opId: "ns.cascade", inputs: ns, needs: ["namespaceId"]),
            RunStep(opId: "app.nsFor", inputs: { f in ["appId": f["appId"] ?? ""] }, needs: ["appId"]),
            RunStep(
                opId: "ns.groupCreate",
                inputs: { f in
                    ["namespaceId": f["namespaceId"] ?? "", "body": #"{"groupName":"run-all","visibility":"open"}"#]
                },
                captures: ["groupId": "groupId"], needs: ["namespaceId"]),
            RunStep(opId: "grp.info", inputs: group, needs: ["groupId"]),
            RunStep(opId: "grp.contexts", inputs: group, needs: ["groupId"]),
            RunStep(opId: "grp.defCaps", inputs: group, needs: ["groupId"]),
            RunStep(opId: "grp.subVis", inputs: group, needs: ["groupId"]),
            RunStep(opId: "grp.memberDevices", inputs: group, needs: ["groupId"]),
            RunStep(opId: "mem.list", inputs: group, captures: ["member": "identity"], needs: ["groupId"]),
            RunStep(opId: "set.grpMetaGet", inputs: group, needs: ["groupId"]),
            RunStep(opId: "set.teeGet", inputs: group, needs: ["groupId"]),
            RunStep(opId: "up.status", inputs: group, needs: ["groupId"]),
            RunStep(
                opId: "grp.subgroups", inputs: { f in ["groupId": f["namespaceId"] ?? ""] }, needs: ["namespaceId"]),
            RunStep(
                opId: "ctx.create",
                inputs: { f in
                    [
                        "body":
                            #"{"applicationId":"\#(f["appId"] ?? "")","groupId":"\#(f["groupId"] ?? "")","name":"run-all"}"#
                    ]
                },
                captures: ["contextId": "contextId", "identity": "memberPublicKey"], needs: ["appId", "groupId"]),
            RunStep(opId: "ctx.get", inputs: ctx, needs: ["contextId"]),
            RunStep(opId: "ctx.group", inputs: ctx, needs: ["contextId"]),
            RunStep(opId: "ctx.storage", inputs: ctx, needs: ["contextId"]),
            RunStep(opId: "cid.list", inputs: ctx, needs: ["contextId"]),
            RunStep(opId: "cid.owned", inputs: ctx, needs: ["contextId"]),
            RunStep(opId: "app.ctxFor", inputs: { f in ["appId": f["appId"] ?? ""] }, needs: ["appId"]),
            RunStep(opId: "app.ctxExec", inputs: { f in ["appId": f["appId"] ?? ""] }, needs: ["appId"]),
            RunStep(
                opId: "mem.getCaps",
                inputs: { f in ["groupId": f["groupId"] ?? "", "identity": f["member"] ?? ""] },
                needs: ["groupId", "member"]),
            RunStep(
                opId: "mem.getMeta",
                inputs: { f in ["groupId": f["groupId"] ?? "", "identity": f["member"] ?? ""] },
                needs: ["groupId", "member"]),
            RunStep(
                opId: "rpc.execute",
                inputs: { f in
                    ["contextId": f["contextId"] ?? "", "method": "set", "args": #"{"key":"run-all","value":"ok"}"#]
                },
                needs: ["contextId"]),
            RunStep(
                opId: "rpc.execute",
                inputs: { f in ["contextId": f["contextId"] ?? "", "method": "get", "args": #"{"key":"run-all"}"#] },
                expect: { $0.contains("\"ok\"") ? nil : "get did not return the value set just before" },
                needs: ["contextId"]),
            RunStep(
                opId: "al.ctxCreate",
                inputs: { f in ["body": #"{"alias":"\#(alias)","contextId":"\#(f["contextId"] ?? "")"}"#] },
                needs: ["contextId"]),
            RunStep(opId: "al.ctxLookup", inputs: { _ in ["name": alias] }, needs: ["contextId"]),
            RunStep(opId: "al.ctxDelete", inputs: { _ in ["name": alias] }, needs: ["contextId"]),
            RunStep(
                opId: "al.appCreate",
                inputs: { f in ["body": #"{"alias":"\#(alias)","applicationId":"\#(f["appId"] ?? "")"}"#] },
                needs: ["appId"]),
            RunStep(opId: "al.appLookup", inputs: { _ in ["name": alias] }, needs: ["appId"]),
            RunStep(opId: "al.appDelete", inputs: { _ in ["name": alias] }, needs: ["appId"]),
            RunStep(
                opId: "blob.upload",
                inputs: { f in ["text": "run-all \(alias)", "contextId": f["contextId"] ?? ""] },
                captures: ["blobId": "blobId"], needs: ["contextId"]),
            RunStep(opId: "blob.info", inputs: blob, needs: ["blobId"]),
            RunStep(opId: "blob.get", inputs: blob, needs: ["blobId"]),
            RunStep(opId: "blob.delete", inputs: blob, needs: ["blobId"]),
            RunStep(opId: "ns.invite", inputs: ns, needs: ["namespaceId"]),
            RunStep(opId: "ctx.sync", inputs: ctx, needs: ["contextId"]),
            // Cleanup, newest first.
            RunStep(opId: "ctx.delete", inputs: ctx, needs: ["contextId"]),
            RunStep(opId: "ns.delete", inputs: ns, needs: ["namespaceId"]),
            RunStep(
                opId: "app.uninstall", inputs: { f in ["appId": f["appId"] ?? ""] }, needs: ["appId", "installedByRun"]),
        ]
    }

    private static let ns: @Sendable ([String: String]) -> [String: String] = {
        ["namespaceId": $0["namespaceId"] ?? ""]
    }
    private static let group: @Sendable ([String: String]) -> [String: String] = { ["groupId": $0["groupId"] ?? ""] }
    private static let ctx: @Sendable ([String: String]) -> [String: String] = { ["contextId": $0["contextId"] ?? ""] }
    private static let blob: @Sendable ([String: String]) -> [String: String] = { ["blobId": $0["blobId"] ?? ""] }

    /// Why an operation is not run automatically.
    static func skipReason(_ op: SDKOperation, signedInToNode: Bool) -> String {
        if op.cloudRun != nil { return "Cloud & relay: runs from its form on a Cloud session" }
        if !signedInToNode { return "Needs a node you sign in to directly" }
        switch op.id {
        case "auth.gen", "auth.refresh", "auth.mock", "auth.revoke", "auth.validate":
            return "Mints or revokes tokens: would replace or end this session"
        case let id where id.hasPrefix("key."):
            return "Changes the node's root or client keys"
        case "ctx.join", "ctx.leave", "ns.join", "ns.leave", "ns.admit", "up.join", "up.joinInherit", "grp.leave",
            "ns.revokeDevice", "mem.add", "mem.remove", "mem.role":
            return "Needs a second node or member"
        case let id where id.hasPrefix("acct."):
            return "Pairs or re-links devices on the account"
        case "ctx.updateApp", "up.upgrade", "up.retry", "ns.abort", "grp.reparent":
            return "Needs a second application version"
        case "rpc.migrate", "rpc.pending":
            return "Needs an app with entry migration (kv-store has none)"
        case "tee.attest", "set.teeSet", "ns.nsProof", "grp.proof":
            return "Needs a TEE node"
        default:
            return "Needs input this run does not create; run it from its form"
        }
    }
}

// MARK: - The runner

@MainActor
final class RunAllModel: ObservableObject {
    enum Status: Equatable {
        case pending, running, passed, failed(String), skipped(String)
    }

    struct Result: Identifiable {
        let id: Int
        /// The explorer operation, or nil for a contract test case.
        let op: SDKOperation?
        let title: String
        let subtitle: String
        let summary: String
        let phase: String
        /// The contract case, for a "Contract" row.
        var contractCase: ContractSpec.Case?
        /// Index into the lifecycle steps, for a lifecycle row.
        var step: Int?
        var inputs: [String: String] = [:]
        var status: Status = .pending
        var output = ""
        var millis = 0

        init(id: Int, op: SDKOperation, phase: String, step: Int? = nil) {
            self.id = id; self.op = op; self.phase = phase; self.step = step
            title = op.name; subtitle = op.category; summary = op.summary
        }

        init(id: Int, contractCase: ContractSpec.Case) {
            self.id = id; op = nil; phase = "Contract"; self.contractCase = contractCase
            title = contractCase.name; subtitle = contractCase.group; summary = "scaffolding-e2e · \(contractCase.id)"
        }
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var running = false
    @Published private(set) var finishedAt: Date?

    var passed: Int { results.filter { $0.status == .passed }.count }
    var failed: Int { results.filter { if case .failed = $0.status { return true } else { return false } }.count }
    var skipped: Int { results.filter { if case .skipped = $0.status { return true } else { return false } }.count }
    var done: Int { results.filter { $0.status != .pending && $0.status != .running }.count }

    func run(mero: Mero?, signedInToNode: Bool) async {
        guard !running else { return }
        running = true
        finishedAt = nil
        defer {
            running = false
            finishedAt = Date()
        }

        let byId = Dictionary(sdkOperations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reads = sdkOperations.filter { $0.fields.isEmpty && $0.cloudRun == nil }
        let stamp = String(Int(Date().timeIntervalSince1970))
        let steps = signedInToNode ? RunAllPlan.lifecycle(stamp: stamp) : []

        var planned: [Result] = []
        for op in reads { planned.append(Result(id: planned.count, op: op, phase: "Reads")) }
        for (index, step) in steps.enumerated() {
            if let op = byId[step.opId] {
                planned.append(Result(id: planned.count, op: op, phase: "Lifecycle", step: index))
            }
        }
        let covered = Set(planned.compactMap { $0.op?.id })
        let spec = signedInToNode ? ContractSpec.load() : nil
        for testCase in spec?.cases ?? [] {
            planned.append(Result(id: planned.count, contractCase: testCase))
        }
        for op in sdkOperations where !covered.contains(op.id) {
            var r = Result(id: planned.count, op: op, phase: "Skipped")
            r.status = .skipped(RunAllPlan.skipReason(op, signedInToNode: signedInToNode))
            planned.append(r)
        }
        results = planned

        guard let mero else {
            for i in results.indices where results[i].status == .pending {
                results[i].status = .skipped("No admin session yet")
            }
            return
        }

        var fixtures: [String: String] = [:]
        if signedInToNode, let apps = try? await mero.admin.listApplications(),
            apps.apps.contains(where: { $0.package == RunAllPlan.package }) == false
        {
            // Only uninstall at the end what this run installed.
            fixtures["installedByRun"] = "1"
        }

        for i in results.indices where results[i].status == .pending {
            guard let op = results[i].op else { continue }
            let step: RunStep? = results[i].step.map { steps[$0] }

            if let step, let missing = step.needs.first(where: { fixtures[$0] == nil }) {
                results[i].status = .skipped(
                    missing == "installedByRun"
                        ? "\(RunAllPlan.package) was already installed; left in place"
                        : "An earlier step did not produce \(missing)")
                continue
            }
            let inputs = step?.inputs(fixtures) ?? [:]
            results[i].inputs = inputs
            results[i].status = .running
            let started = Date()
            do {
                let output = try await op.run(mero, inputs)
                results[i].output = output
                results[i].millis = Int(Date().timeIntervalSince(started) * 1000)
                if let reason = step?.expect?(output) {
                    results[i].status = .failed(reason)
                } else {
                    results[i].status = .passed
                    for (key, jsonKey) in step?.captures ?? [:] {
                        if let value = Self.find(jsonKey, in: output) { fixtures[key] = value }
                    }
                }
            } catch {
                results[i].millis = Int(Date().timeIntervalSince(started) * 1000)
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                results[i].output = message
                results[i].status = .failed(message)
            }
        }

        if let spec { await runContract(spec, mero: mero) }

    }

    /// The scaffolding-e2e contract tests: install the app from the registry,
    /// make a namespace, group and context, run every case in order with one
    /// shared `${run}` prefix, then delete what was made.
    private func runContract(_ spec: ContractSpec, mero: Mero) async {
        let rows = results.indices.filter { results[$0].phase == "Contract" }
        func skipAll(_ why: String) { for i in rows { results[i].status = .skipped(why) } }
        do {
            let installedBefore = (try? await mero.admin.listApplications())?.apps.contains {
                $0.package == spec.package
            }
            guard
                let version = try await mero.admin.getRegistryVersions(
                    registryUrl: RunAllPlan.registry, packageName: spec.package
                ).first
            else { return skipAll("\(spec.package) is not on the registry") }
            let app = try await mero.admin.installFromRegistry(packageName: spec.package, version: version)
            let ns = try await mero.admin.createNamespace(
                CreateNamespaceRequest(applicationId: app.applicationId, name: "run-all-contract"))
            let group = try await mero.admin.createGroupInNamespace(
                ns.namespaceId, request: CreateGroupInNamespaceRequest(groupName: "contract", visibility: "open"))
            let context = try await mero.admin.createContext(
                CreateContextRequest(applicationId: app.applicationId, groupId: group.groupId, name: "contract"))

            let runner = ContractCaseRunner(
                mero: mero, contextId: context.contextId,
                run: "e2e_" + String(Int(Date().timeIntervalSince1970), radix: 36))
            for i in rows {
                guard let testCase = results[i].contractCase else { continue }
                results[i].status = .running
                let started = Date()
                let why = await runner.run(testCase)
                results[i].millis = Int(Date().timeIntervalSince(started) * 1000)
                results[i].status = why.map { .failed($0) } ?? .passed
                results[i].output = why ?? "passed"
            }

            _ = try? await mero.admin.deleteContext(context.contextId, request: nil)
            _ = try? await mero.admin.deleteNamespace(ns.namespaceId, request: nil)
            if installedBefore == false { _ = try? await mero.admin.uninstallApplication(app.applicationId) }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            for i in rows where results[i].status == .pending {
                results[i].status = .failed("Setup failed: \(message)")
            }
        }
    }

    /// The first string value under `key` anywhere in a JSON document, or the
    /// first element of a top-level array for `$first`.
    static func find(_ key: String, in json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        else { return nil }
        if key == "$first" {
            return (object as? [Any])?.first.map { "\($0)" }
        }
        func walk(_ node: Any) -> String? {
            if let dict = node as? [String: Any] {
                if let value = dict[key] as? String { return value }
                for value in dict.values { if let found = walk(value) { return found } }
            } else if let array = node as? [Any] {
                for value in array { if let found = walk(value) { return found } }
            }
            return nil
        }
        return walk(object)
    }

    func report() -> String {
        var lines = ["MeroKit Run all — \(passed) passed, \(failed) failed, \(skipped) skipped"]
        for r in results {
            switch r.status {
            case .passed: lines.append("PASS  \(r.title) (\(r.millis) ms)")
            case .failed(let why): lines.append("FAIL  \(r.title): \(why)")
            case .skipped(let why): lines.append("SKIP  \(r.title): \(why)")
            case .pending, .running: lines.append("....  \(r.title)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Views

/// The "Run all" entry at the top of the SDK list.
struct RunAllEntry: View {
    var body: some View {
        NavigationLink {
            RunAllView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Cal.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Cal.lime))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Run all").font(.headline).foregroundColor(Cal.text)
                    Text("Test every method against this session and see what passes")
                        .font(.footnote).foregroundColor(Cal.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(Cal.textFaint)
            }
            .padding(16)
            .background(Cal.surface)
            .overlay(RoundedRectangle(cornerRadius: Cal.cardRadius).stroke(Cal.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Cal.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("runAllEntry")
    }
}

struct RunAllView: View {
    enum Filter: String, CaseIterable { case all = "All", failed = "Failed", passed = "Passed", skipped = "Skipped" }

    @EnvironmentObject private var session: MeroSession
    @StateObject private var model = RunAllModel()
    @State private var filter: Filter = .all
    @State private var copied = false

    private var signedInToNode: Bool { session.devNodeURL != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard
                if !model.results.isEmpty {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(phases, id: \.self) { phase in
                        let rows = visible.filter { $0.phase == phase }
                        if !rows.isEmpty {
                            CalSection(title: "\(phase) · \(rows.count)") {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, result in
                                    NavigationLink {
                                        RunResultDetail(result: result)
                                    } label: {
                                        RunResultRow(result: result)
                                    }
                                    .buttonStyle(.plain)
                                    if idx < rows.count - 1 { RowDivider() }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Cal.screenPad + 4)
            .padding(.vertical, 12)
        }
        .background(Cal.bg.ignoresSafeArea())
        .navigationTitle("Run all")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.finishedAt != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = model.report()
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("Copy report")
                }
            }
        }
    }

    private let phases = ["Reads", "Lifecycle", "Contract", "Skipped"]

    private var visible: [RunAllModel.Result] {
        model.results.filter { r in
            switch (filter, r.status) {
            case (.all, _): return true
            case (.failed, .failed): return true
            case (.passed, .passed): return true
            case (.skipped, .skipped): return true
            default: return false
            }
        }
    }

    private var summaryCard: some View {
        CalCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    signedInToNode
                        ? "Runs every read, a full lifecycle on a throwaway kv-store app (install, namespace, "
                            + "context, RPC, aliases, blob), then the scaffolding-e2e contract tests, and deletes "
                            + "what it made."
                        : "Runs every read through your Cloud session. The lifecycle needs a node you sign in to "
                            + "directly (Manually enter node URL)."
                )
                .font(.footnote)
                .foregroundColor(Cal.textDim)
                .fixedSize(horizontal: false, vertical: true)

                if !model.results.isEmpty {
                    ProgressView(value: Double(model.done), total: Double(max(model.results.count, 1)))
                        .tint(model.failed > 0 ? Cal.error : Cal.accentInk)
                    HStack(spacing: 8) {
                        StatPill(value: model.passed, label: "passed", tone: Cal.success, bg: Color(hex: 0xEEF8E4))
                        StatPill(value: model.failed, label: "failed", tone: Cal.error, bg: Cal.errorSoft)
                        StatPill(value: model.skipped, label: "skipped", tone: Cal.textDim, bg: Cal.bgSubtle)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("runAllSummary")
                }

                Button {
                    copied = false
                    filter = .all
                    Task { await model.run(mero: session.mero, signedInToNode: signedInToNode) }
                } label: {
                    HStack(spacing: 10) {
                        if model.running {
                            ProgressView().tint(Cal.text)
                            Text("Running \(model.done) of \(model.results.count)…")
                        } else {
                            Image(systemName: model.finishedAt == nil ? "play.fill" : "arrow.clockwise")
                            Text(model.finishedAt == nil ? "Run all" : "Run again")
                        }
                    }
                }
                .buttonStyle(CalPrimaryButtonStyle(enabled: !model.running))
                .disabled(model.running)
                .accessibilityIdentifier("runAllButton")

                if model.finishedAt != nil {
                    // The whole report for UI tests, which cannot read the pasteboard.
                    Text(model.report())
                        .font(.system(size: 1))
                        .opacity(0.01)
                        .frame(height: 1)
                        .accessibilityIdentifier("runAllReport")
                }
            }
        }
    }
}

private struct StatPill: View {
    let value: Int
    let label: String
    let tone: Color
    let bg: Color
    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)").font(.subheadline.weight(.bold).monospacedDigit())
            Text(label).font(.caption)
        }
        .foregroundColor(tone)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(bg))
    }
}

private struct RunResultRow: View {
    let result: RunAllModel.Result
    var body: some View {
        HStack(spacing: 12) {
            statusIcon.frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
                Text(detail).font(.caption).foregroundColor(detailColor).lineLimit(2)
            }
            Spacer(minLength: 8)
            if result.status == .passed {
                Text("\(result.millis) ms").font(.caption.monospacedDigit()).foregroundColor(Cal.textFaint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var statusIcon: some View {
        switch result.status {
        case .pending: Image(systemName: "circle").foregroundColor(Cal.borderStrong)
        case .running: ProgressView().scaleEffect(0.8)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundColor(Cal.success)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(Cal.error)
        case .skipped: Image(systemName: "minus.circle").foregroundColor(Cal.textFaint)
        }
    }

    private var detail: String {
        switch result.status {
        case .failed(let why), .skipped(let why): return why
        default: return result.subtitle
        }
    }

    private var detailColor: Color {
        if case .failed = result.status { return Cal.error }
        return Cal.textFaint
    }
}

private struct RunResultDetail: View {
    let result: RunAllModel.Result
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title).font(.title3.bold()).foregroundColor(Cal.text)
                    Text(result.summary).font(.subheadline).foregroundColor(Cal.textDim)
                }
                if !result.inputs.isEmpty {
                    block(
                        "Inputs",
                        result.inputs.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
                            .joined(separator: "\n"))
                }
                switch result.status {
                case .skipped(let why): Callout(tone: .info, text: why)
                case .failed(let why):
                    Callout(tone: .danger, text: why)
                    if !result.output.isEmpty && result.output != why { block("Output", result.output) }
                default:
                    if !result.output.isEmpty { block("Response", result.output) }
                }
            }
            .padding(.horizontal, Cal.screenPad)
            .padding(.vertical, 16)
        }
        .background(Cal.bg.ignoresSafeArea())
        .navigationTitle(result.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: title)
            Text(text)
                .font(Cal.mono)
                .foregroundColor(Cal.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Cal.surface2)
                .clipShape(RoundedRectangle(cornerRadius: Cal.controlRadius))
        }
    }
}
