import MeroKit
import MeroKitUI
import SwiftUI
import UIKit

// MARK: - Root: routes Sign-in ⇄ Explorer on auth state

struct ExplorerRootView: View {
    @EnvironmentObject private var session: MeroSession
    var body: some View {
        ZStack {
            Cal.bg.ignoresSafeArea()
            if session.isAuthenticated {
                ExplorerView()
            } else {
                CalimeroLoginView()
            }
        }
        .tint(Cal.accentInk)
        .task { await session.start() }
        .onOpenURL { url in Task { await session.handleCallback(url) } }
    }
}

// MARK: - Sign in (Cloud only)

/// One "Continue with Calimero" button: the wallet opens in the system sheet,
/// the person approves this device with their passkey, and the app connects to
/// the relay that serves their account. No node URL, no password.
struct CalimeroLoginView: View {
    @EnvironmentObject private var session: MeroSession
    @State private var showLogs = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: max(32, geo.size.height * 0.12))
                    CalLogo(size: 36)
                    card
                    Button {
                        showLogs = true
                    } label: {
                        Label("Diagnostics", systemImage: "list.bullet.rectangle")
                            .font(.footnote)
                            .foregroundColor(Cal.textFaint)
                    }
                    Spacer(minLength: 24)
                }
                .frame(minHeight: geo.size.height)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Cal.screenPad)
            }
        }
        .background(Cal.bg.ignoresSafeArea())
        .sheet(isPresented: $showLogs) { LogsView() }
    }

    private var card: some View {
        CalCard(padding: 24) {
            VStack(spacing: 18) {
                IconTile(systemName: "person.badge.key", accent: true, size: 44)
                VStack(spacing: 8) {
                    Text("Sign in to Calimero")
                        .font(.title3.weight(.bold))
                        .foregroundColor(Cal.text)
                        .accessibilityIdentifier("loginTitle")
                    Text(
                        "You'll approve this device with your passkey on the Calimero wallet, then come straight "
                            + "back. Your account key never leaves the wallet."
                    )
                    .font(.subheadline)
                    .foregroundColor(Cal.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "That one device certificate finds the relay serving your account, writes through it, "
                            + "and reads your spaces and live events. Nothing to paste in."
                    )
                    .font(.footnote)
                    .foregroundColor(Cal.textFaint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let error = session.errorMessage {
                    Callout(tone: .danger, text: error)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("loginError")
                }

                Button {
                    Task { await session.signInWithCloud() }
                } label: {
                    HStack(spacing: 8) {
                        if session.isLoading {
                            ProgressView().tint(Cal.text)
                        } else {
                            Image(systemName: "key.fill").font(.footnote.weight(.semibold))
                        }
                        Text("Continue with Calimero")
                    }
                }
                .buttonStyle(CalPrimaryButtonStyle(enabled: !session.isLoading))
                .disabled(session.isLoading)
                .accessibilityIdentifier("cloudSignInButton")
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Explorer landing (Chat + Explore SDK)

struct ExplorerView: View {
    @EnvironmentObject private var session: MeroSession
    @State private var showLogs = false
    @State private var showChat = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    accountCard
                    if let note = session.note {
                        Callout(tone: session.relayURL == nil ? .info : .warning, text: note)
                            .accessibilityIdentifier("sessionNote")
                    }
                    Eyebrow(text: "Examples")
                    chatCard
                    exploreCard
                }
                .padding(.horizontal, Cal.screenPad)
                .padding(.vertical, 16)
            }
            .background(Cal.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Cal.surface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { CalLogo(size: 26) }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLogs = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Diagnostics")
                    .foregroundColor(Cal.textDim)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await session.logout() } }
                        .foregroundColor(Cal.textDim)
                        .accessibilityIdentifier("logoutButton")
                }
            }
        }
        .sheet(isPresented: $showLogs) { LogsView() }
        .sheet(isPresented: $showChat) {
            if let chat = session.chat {
                ChatHomeView(service: chat)
            }
        }
    }

    private var accountCard: some View {
        CalCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ChatAvatar(name: session.displayName.isEmpty ? "?" : session.displayName, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Cal.text)
                            .accessibilityIdentifier("homeUser")
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.relayURL != nil || session.devNodeURL != nil ? Cal.lime : Cal.warning)
                                .frame(width: 8, height: 8)
                            Text(statusText).font(.footnote).foregroundColor(Cal.textFaint)
                        }
                    }
                    Spacer()
                }
                TechnicalDetails(rows: technicalRows)
            }
        }
        .accessibilityIdentifier("accountCard")
    }

    private var statusText: String {
        if session.devNodeURL != nil { return "Development node" }
        guard let relay = session.relayURL else { return "Signed in, no relay yet" }
        return URL(string: relay)?.host ?? relay
    }

    private var technicalRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let account = session.account { rows.append(("Account", account)) }
        if let device = session.connection?.session.device { rows.append(("Device", device)) }
        if let relay = session.relayURL { rows.append(("Relay", relay)) }
        if let key = session.connection?.nodeKey { rows.append(("Node key", key)) }
        if let node = session.devNodeURL { rows.append(("Node", node)) }
        return rows
    }

    private var chatCard: some View {
        Button {
            showChat = true
        } label: {
            entry(
                icon: "bubble.left.and.bubble.right",
                title: "Chat",
                subtitle: "Spaces, channels and messages on curb",
                accent: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("openChat")
    }

    private var exploreCard: some View {
        NavigationLink {
            SDKListView()
        } label: {
            entry(
                icon: "square.grid.2x2",
                title: "Explore SDK",
                subtitle: "\(sdkOperations.count) methods across \(sdkCategories.count) categories",
                accent: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("exploreSDK")
    }

    private func entry(icon: String, title: String, subtitle: String, accent: Bool) -> some View {
        HStack(spacing: 12) {
            IconTile(systemName: icon, accent: accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
                Text(subtitle).font(.footnote).foregroundColor(Cal.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundColor(Cal.textFaint)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .background(Cal.surface)
        .overlay(RoundedRectangle(cornerRadius: Cal.cardRadius).stroke(Cal.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Cal.cardRadius))
    }
}

// MARK: - SDK list (categorized, searchable) — behind "Explore SDK"

struct SDKListView: View {
    @State private var search = ""
    @State private var expanded: Set<String> = []

    private var filtered: [(category: String, ops: [SDKOperation])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return sdkCategories.compactMap { cat in
            let ops = sdkOperations.filter { op in
                op.category == cat
                    && (q.isEmpty || op.name.lowercased().contains(q) || op.summary.lowercased().contains(q)
                        || op.category.lowercased().contains(q))
            }
            return ops.isEmpty ? nil : (cat, ops)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                searchField
                sectionLabel(search.isEmpty ? "SDK Options" : "\(matchCount) results")
                ForEach(filtered, id: \.category) { section in
                    categoryCard(section)
                }
            }
            .padding(.horizontal, Cal.screenPad)
            .padding(.vertical, 14)
        }
        .background(Cal.bg)
        .navigationTitle("Explore SDK")
        .navigationBarTitleDisplayMode(.inline)
    }

    // A plain, always-visible search field (instead of `.searchable`, whose bar
    // collapses on a pushed screen and isn't reliably reachable in UI tests).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.footnote).foregroundColor(Cal.textDim)
            TextField("Search \(sdkOperations.count) methods", text: $search)
                .font(.subheadline)
                .foregroundColor(Cal.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("sdkSearch")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Cal.textDim)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Cal.surface2)
        .overlay(RoundedRectangle(cornerRadius: Cal.controlRadius).stroke(Cal.borderStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Cal.controlRadius))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.medium))
            .tracking(0.5)
            .foregroundColor(Cal.textFaint)
    }

    private var matchCount: Int { filtered.reduce(0) { $0 + $1.ops.count } }

    private func expandBinding(_ category: String) -> Binding<Bool> {
        Binding(
            get: { !search.isEmpty || expanded.contains(category) },
            set: { isOn in
                if isOn { expanded.insert(category) } else { expanded.remove(category) }
            })
    }

    private func categoryCard(_ section: (category: String, ops: [SDKOperation])) -> some View {
        DisclosureGroup(isExpanded: expandBinding(section.category)) {
            VStack(spacing: 0) {
                ForEach(Array(section.ops.enumerated()), id: \.element.id) { idx, op in
                    NavigationLink {
                        OperationRunnerView(op: op)
                    } label: {
                        row(op)
                    }
                    if idx < section.ops.count - 1 { Divider().overlay(Cal.border) }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(section.category).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
                Spacer()
                Text("\(section.ops.count)").font(.caption).foregroundColor(Cal.textDim)
            }
        }
        .padding(12)
        .background(Cal.surface)
        .overlay(RoundedRectangle(cornerRadius: Cal.cardRadius).stroke(Cal.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Cal.cardRadius))
        .tint(Cal.accentInk)
    }

    private func row(_ op: SDKOperation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(op.name).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
                Text(op.summary).font(.caption).foregroundColor(Cal.textDim)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Cal.textDim)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Operation runner (form + response)

struct OperationRunnerView: View {
    let op: SDKOperation
    @EnvironmentObject private var session: MeroSession
    @State private var inputs: [String: String] = [:]
    @State private var output = ""
    @State private var failed = false
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(op.name).font(.title3.bold()).foregroundColor(Cal.text)
                    Text(op.summary).font(.subheadline).foregroundColor(Cal.textDim)
                    Text(op.category).font(.caption.weight(.medium)).foregroundColor(Cal.accentInk)
                }

                ForEach(op.fields) { field in
                    fieldView(field)
                }

                Button {
                    run()
                } label: {
                    if running { ProgressView().tint(Cal.text) } else { Text("Run") }
                }
                .buttonStyle(CalPrimaryButtonStyle())
                .disabled(running)

                if !output.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: failed ? "Error" : "Response")
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(output)
                                .font(Cal.mono)
                                .foregroundColor(failed ? Cal.error : Cal.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(Cal.surface2)
                        .overlay(
                            RoundedRectangle(cornerRadius: Cal.controlRadius).stroke(Cal.borderStrong, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Cal.controlRadius))
                    }
                }
            }
            .padding(.horizontal, Cal.screenPad)
            .padding(.vertical, 16)
        }
        .background(Cal.bg.ignoresSafeArea())
        .navigationTitle(op.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func fieldView(_ field: OpField) -> some View {
        let binding = Binding(get: { inputs[field.id] ?? "" }, set: { inputs[field.id] = $0 })
        switch field.kind {
        case .line:
            CalField(title: field.label, text: binding, placeholder: field.placeholder)
        case .multiline:
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label).font(.footnote.weight(.medium)).foregroundColor(Cal.text)
                TextEditor(text: binding)
                    .font(Cal.mono)
                    .foregroundColor(Cal.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Cal.surface2)
                    .overlay(RoundedRectangle(cornerRadius: Cal.controlRadius).stroke(Cal.borderStrong, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Cal.controlRadius))
            }
        }
    }

    private func run() {
        running = true
        let captured = inputs
        let mero = session.mero
        let context = CloudOpContext(
            signIn: session.signIn, relay: session.relay, session: session.connection?.session,
            connection: session.connection)
        Task {
            do {
                let result: String
                if let cloudRun = op.cloudRun {
                    result = try await cloudRun(context, captured)
                } else if let mero {
                    result = try await op.run(mero, captured)
                } else {
                    result = "Admin reads need the relay session, which is not established yet."
                }
                await MainActor.run {
                    output = result; failed = false; running = false
                }
            } catch {
                await MainActor.run {
                    output = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    failed = true; running = false
                }
            }
        }
    }
}

// MARK: - Diagnostics log

struct LogsView: View {
    @EnvironmentObject private var session: MeroSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if session.logs.isEmpty {
                            Text("No activity yet.")
                                .font(.footnote).foregroundColor(Cal.textDim)
                        }
                        ForEach(session.logs) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: line.level.symbol)
                                    .font(.caption2)
                                    .foregroundColor(color(line.level))
                                    .frame(width: 14, alignment: .leading)
                                Text(line.text)
                                    .foregroundColor(Cal.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(Cal.mono)
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .onChange(of: session.logs.count) { _ in
                    if let last = session.logs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .background(Cal.bg)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { session.clearLogs() }.foregroundColor(Cal.accentInk)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            UIPasteboard.general.string = session.logText()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        ShareLink(item: session.logText()) { Image(systemName: "square.and.arrow.up") }
                        Button("Done") { dismiss() }
                    }
                    .foregroundColor(Cal.accentInk)
                }
            }
        }
        .tint(Cal.accentInk)
    }

    private func color(_ level: MeroSession.LogLine.Level) -> Color {
        switch level {
        case .err: return Cal.error
        case .ok: return Cal.success
        case .warn: return Cal.warning
        case .req: return Cal.text
        case .info: return Cal.textDim
        }
    }
}
