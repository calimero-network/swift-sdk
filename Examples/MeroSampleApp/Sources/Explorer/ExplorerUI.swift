import MeroKit
import SwiftUI

// MARK: - Root: routes Login ⇄ Explorer on auth state

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
        .preferredColorScheme(.dark)
        .tint(Cal.lime)
    }
}

// MARK: - Login (Calimero-branded)

struct CalimeroLoginView: View {
    @EnvironmentObject private var session: MeroSession
    @State private var nodeURL = "http://localhost:4001"
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: max(48, geo.size.height * 0.16))
                    header
                    Spacer(minLength: 34)
                    form
                    Spacer(minLength: 40)
                }
                .frame(minHeight: geo.size.height)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 26)
            }
        }
        .background(
            ZStack {
                Cal.bg
                RadialGradient(
                    colors: [Cal.lime.opacity(0.16), .clear],
                    center: .init(x: 0.5, y: 0.12), startRadius: 0, endRadius: 320)
            }
            .ignoresSafeArea()
        )
    }

    private var header: some View {
        VStack(spacing: 18) {
            Image("CalimeroIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 62, height: 62)
                .shadow(color: Cal.lime.opacity(0.25), radius: 18, y: 4)
            VStack(spacing: 7) {
                Text("SDK Explorer")
                    .font(.system(.title, design: .default).weight(.bold))
                    .foregroundColor(Cal.text)
                    .accessibilityIdentifier("loginTitle")
                Text("Explore the full MeroKit SDK on any Calimero node.")
                    .font(.subheadline)
                    .foregroundColor(Cal.textDim)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var form: some View {
        VStack(spacing: 11) {
            MinimalField(icon: "globe", placeholder: "Node URL", text: $nodeURL)
                .accessibilityIdentifier("nodeURLField")
            MinimalField(icon: "person", placeholder: "Username", text: $username)
                .accessibilityIdentifier("usernameField")
            MinimalField(icon: "lock", placeholder: "Password", text: $password, secure: true)
                .accessibilityIdentifier("passwordField")

            if let error = session.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(Cal.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("loginError")
            }

            Button {
                Task { await session.login(nodeURL: nodeURL, username: username, password: password) }
            } label: {
                if session.isLoading { ProgressView().tint(Cal.bg) } else { Text("Connect") }
            }
            .buttonStyle(CalPrimaryButtonStyle())
            .disabled(session.isLoading)
            .accessibilityIdentifier("loginButton")
            .padding(.top, 5)
        }
    }
}

// MARK: - Explorer list (categorized, searchable)

struct ExplorerView: View {
    @EnvironmentObject private var session: MeroSession
    @State private var search = ""

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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ForEach(filtered, id: \.category) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.category.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundColor(Cal.lime)
                            VStack(spacing: 0) {
                                ForEach(Array(section.ops.enumerated()), id: \.element.id) { idx, op in
                                    NavigationLink { OperationRunnerView(op: op) } label: { row(op) }
                                    if idx < section.ops.count - 1 {
                                        Divider().overlay(Cal.border)
                                    }
                                }
                            }
                            .background(Cal.surface)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Cal.border, lineWidth: 1))
                            .cornerRadius(12)
                        }
                    }
                }
                .padding(16)
            }
            .background(Cal.bg)
            .navigationTitle("MeroKit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { CalLogo(size: 22) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log Out") { Task { await session.logout() } }
                        .foregroundColor(Cal.lime)
                }
            }
        }
        .searchable(text: $search, prompt: "Search \(sdkOperations.count) methods")
    }

    private var header: some View {
        CalCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.username.isEmpty ? "connected" : session.username)
                    .font(.headline).foregroundColor(Cal.text)
                Text(session.nodeURL).font(.caption).foregroundColor(Cal.textDim)
                if !session.nodeSummary.isEmpty {
                    Text(session.nodeSummary).font(.caption2).foregroundColor(Cal.lime)
                }
                Text("\(sdkOperations.count) SDK methods across \(sdkCategories.count) categories")
                    .font(.caption2).foregroundColor(Cal.textDim).padding(.top, 2)
            }
        }
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
                    Text(op.category).font(.caption2.weight(.semibold)).foregroundColor(Cal.lime)
                }

                ForEach(op.fields) { field in
                    fieldView(field)
                }

                Button {
                    run()
                } label: {
                    if running { ProgressView().tint(Cal.bg) } else { Text("Run") }
                }
                .buttonStyle(CalPrimaryButtonStyle())
                .disabled(running)

                if !output.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(failed ? "ERROR" : "RESPONSE")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(failed ? Cal.error : Cal.lime)
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(output)
                                .font(Cal.mono)
                                .foregroundColor(failed ? Cal.error : Cal.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(Cal.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cal.border, lineWidth: 1))
                        .cornerRadius(10)
                    }
                }
            }
            .padding(16)
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
                Text(field.label.uppercased()).font(.caption2.weight(.semibold)).foregroundColor(Cal.textDim)
                TextEditor(text: binding)
                    .font(Cal.mono)
                    .foregroundColor(Cal.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Cal.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cal.border, lineWidth: 1))
                    .cornerRadius(10)
            }
        }
    }

    private func run() {
        guard let mero = session.mero else {
            output = "Not connected."; failed = true; return
        }
        running = true
        let captured = inputs
        Task {
            do {
                let result = try await op.run(mero, captured)
                await MainActor.run { output = result; failed = false; running = false }
            } catch {
                await MainActor.run { output = "\(error)"; failed = true; running = false }
            }
        }
    }
}
