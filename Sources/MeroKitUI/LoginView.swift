#if canImport(SwiftUI)
import SwiftUI

/// A credential login form bound to ``MeroClient``. Accessibility identifiers are
/// set for UI testing (the selectors an XCUITest / Playwright-style test drives).
public struct LoginView: View {
    @EnvironmentObject private var client: MeroClient

    @State private var nodeURL: String
    @State private var username: String = ""
    @State private var password: String = ""

    public init(defaultNodeURL: String = "http://localhost:4001") {
        _nodeURL = State(initialValue: defaultNodeURL)
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Calimero")
                .font(.title2).bold()
                .accessibilityIdentifier("loginTitle")

            TextField("Node URL", text: $nodeURL)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .accessibilityIdentifier("nodeURLField")

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .accessibilityIdentifier("usernameField")

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("passwordField")

            if let error = client.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.footnote)
                    .accessibilityIdentifier("loginError")
            }

            Button {
                Task { await client.login(nodeURL: nodeURL, username: username, password: password) }
            } label: {
                if client.isLoading {
                    ProgressView()
                } else {
                    Text("Log In").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(client.isLoading)
            .accessibilityIdentifier("loginButton")

            Spacer()
        }
        .padding()
    }
}
#endif
