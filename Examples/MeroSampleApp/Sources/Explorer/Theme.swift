import SwiftUI

/// Calimero brand palette (dark + lime), lifted from auth-frontend's theme.
enum Cal {
    static let bg = Color(hex: 0x0A0E13)
    static let surface = Color(hex: 0x14181F)
    static let surface2 = Color(hex: 0x1B212B)
    static let border = Color.white.opacity(0.10)
    static let text = Color.white
    static let textDim = Color.white.opacity(0.60)
    static let lime = Color(hex: 0xA5FF11)
    static let orange = Color(hex: 0xFF7A00)
    static let error = Color(hex: 0xEF4444)
    static let mono = Font.system(.footnote, design: .monospaced)

    /// App-wide horizontal screen padding — tight so content runs almost full-width.
    static let screenPad: CGFloat = 8
}

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Filled lime primary button.
struct CalPrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(enabled ? Cal.lime : Cal.lime.opacity(0.3))
            .foregroundColor(Cal.bg)
            .cornerRadius(10)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Outlined secondary button.
struct CalSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Cal.surface2)
            .foregroundColor(Cal.text)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cal.border, lineWidth: 1))
            .cornerRadius(10)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A rounded surface "card".
struct CalCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Cal.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Cal.border, lineWidth: 1))
            .cornerRadius(12)
    }
}

/// The Calimero wordmark: the real brand icon + "calimero".
struct CalLogo: View {
    var size: CGFloat = 24
    var showWordmark = true
    var body: some View {
        HStack(spacing: 8) {
            Image("CalimeroIcon")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
            if showWordmark {
                Text("calimero")
                    .font(.system(size: size * 0.66, weight: .semibold))
                    .foregroundColor(Cal.text)
                    .tracking(0.5)
            }
        }
    }
}

/// Minimal icon + placeholder field (no external label) — used on the login screen.
struct MinimalField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(Cal.textDim)
                .frame(width: 20)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .font(.subheadline)
            .foregroundColor(Cal.text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Cal.surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Cal.border, lineWidth: 1))
        .cornerRadius(12)
    }
}

/// Dark styled single-line text field.
struct CalField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Cal.textDim)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .font(.subheadline)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .foregroundColor(Cal.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Cal.surface2)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Cal.border, lineWidth: 1))
            .cornerRadius(9)
        }
    }
}
