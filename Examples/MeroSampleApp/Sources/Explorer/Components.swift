import MeroKit
import MeroKitUI
import SwiftUI

/// "Components": MeroKitUI's own sign-in screen, live, with its flags — the
/// mode, the node sign-in method and the theme — so an app author can see
/// each combination before wiring it in.
struct ComponentsEntry: View {
    var body: some View {
        NavigationLink {
            LoginComponentPreview()
        } label: {
            HStack(spacing: 14) {
                IconTile(systemName: "rectangle.portrait.on.rectangle.portrait", accent: true, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Login component").font(.headline).foregroundColor(Cal.text)
                    Text("MeroKitUI's LoginView with every mode and theme")
                        .font(.footnote).foregroundColor(Cal.textDim)
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
        .accessibilityIdentifier("componentsEntry")
    }
}

struct LoginComponentPreview: View {
    enum ThemeChoice: String, CaseIterable {
        case light = "Light", dark = "Dark", custom = "Custom"

        var theme: MeroTheme {
            switch self {
            case .light: return .calimeroLight
            case .dark: return .calimero
            case .custom:
                return MeroTheme.calimeroLight.with {
                    $0.primary = Color(hex: 0x5B5BD6)
                    $0.primaryHover = Color(hex: 0x6E6ADE)
                    $0.primaryText = .white
                    $0.radius = 26
                    $0.titleDesign = .serif
                }
            }
        }
    }

    @StateObject private var client = MeroClient()
    @State private var mode: LoginMode = .cloudAndNode
    @State private var method: NodeSignInMethod = .password
    @State private var themeChoice: ThemeChoice = .light
    @State private var glow = true
    @State private var showOptions = false

    var body: some View {
        LoginView(callbackScheme: MeroSession.callbackScheme, mode: mode, nodeSignIn: method)
            .id("\(mode)-\(method)")
            .environmentObject(client)
            .meroTheme(themeChoice.theme.with { $0.showsGlow = glow })
            .navigationTitle("LoginView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOptions = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Options")
                }
            }
            .sheet(isPresented: $showOptions) { options }
            .overlay(alignment: .bottom) {
                if client.isAuthenticated {
                    Callout(tone: .success, text: "Signed in through the component. This preview does not keep it.")
                        .padding()
                }
            }
    }

    private var options: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    Picker("Mode", selection: $mode) {
                        Text("Cloud + node").tag(LoginMode.cloudAndNode)
                        Text("Cloud only").tag(LoginMode.cloudOnly)
                        Text("Node only").tag(LoginMode.nodeOnly)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Node sign-in") {
                    Picker("Node sign-in", selection: $method) {
                        Text("Username + password").tag(NodeSignInMethod.password)
                        Text("Node login page").tag(NodeSignInMethod.loginPage)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Theme") {
                    Picker("Theme", selection: $themeChoice) {
                        ForEach(ThemeChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Glow", isOn: $glow)
                }
                Section {
                    Text(code).font(Cal.mono).textSelection(.enabled)
                } header: {
                    Text("Code")
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { showOptions = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var code: String {
        let modeName = ".\(mode)"
        let methodName = ".\(method)"
        let theme: String
        switch themeChoice {
        case .light: theme = ".calimeroLight"
        case .dark: theme = ".calimero"
        case .custom: theme = ".calimeroLight.with { $0.primary = .indigo }"
        }
        return """
            LoginView(
              callbackScheme: "myapp",
              mode: \(modeName),
              nodeSignIn: \(methodName))
            .meroTheme(\(theme)\(glow ? "" : ".with { $0.showsGlow = false }"))
            """
    }
}
