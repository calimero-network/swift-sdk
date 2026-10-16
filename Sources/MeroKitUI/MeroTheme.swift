#if canImport(SwiftUI)
import SwiftUI

/// Theme tokens for the MeroKitUI views — mero-react's `MeroTheme`, as SwiftUI
/// values. Apply one with ``SwiftUI/View/meroTheme(_:)``; every MeroKitUI view
/// reads it from the environment.
///
/// The views draw on the system background, so ``background`` and the text
/// tokens are for surfaces an app styles itself; the accent, its text, the
/// error and the radius are what the shipped views use directly.
public struct MeroTheme: Equatable {
    /// Primary accent / call-to-action.
    public var primary: Color
    /// Primary accent, pressed.
    public var primaryHover: Color
    /// Text drawn on ``primary``.
    public var primaryText: Color
    /// Main surface.
    public var background: Color
    /// Secondary surface (inputs, chips).
    public var backgroundSecondary: Color
    /// Tertiary surface (subtle elevation).
    public var backgroundTertiary: Color
    public var border: Color
    public var text: Color
    /// Muted text.
    public var textSecondary: Color
    /// Errors and danger.
    public var error: Color
    /// A modal's backdrop.
    public var overlay: Color
    /// Corner radius, in points.
    public var radius: CGFloat

    public init(
        primary: Color, primaryHover: Color, primaryText: Color, background: Color, backgroundSecondary: Color,
        backgroundTertiary: Color, border: Color, text: Color, textSecondary: Color, error: Color, overlay: Color,
        radius: CGFloat
    ) {
        self.primary = primary
        self.primaryHover = primaryHover
        self.primaryText = primaryText
        self.background = background
        self.backgroundSecondary = backgroundSecondary
        self.backgroundTertiary = backgroundTertiary
        self.border = border
        self.text = text
        self.textSecondary = textSecondary
        self.error = error
        self.overlay = overlay
        self.radius = radius
    }

    /// mero-react's `defaultMeroTheme`: the green palette across Calimero apps,
    /// accent `#A5FF11`.
    public static var calimero: MeroTheme {
        MeroTheme(
            primary: Color(meroHex: 0xA5FF11), primaryHover: Color(meroHex: 0x8ED40D),
            primaryText: Color(meroHex: 0x0D1117), background: Color(meroHex: 0x0D1117),
            backgroundSecondary: Color(meroHex: 0x161B22), backgroundTertiary: Color(meroHex: 0x1C2128),
            border: Color(meroHex: 0x30363D), text: Color(meroHex: 0xE6EDF3), textSecondary: Color(meroHex: 0x8B949E),
            error: Color(meroHex: 0xFF6B6B), overlay: Color.black.opacity(0.75), radius: 8)
    }

    /// A copy with `change` applied — the partial override mero-react's
    /// `resolveMeroTheme` merges.
    public func with(_ change: (inout MeroTheme) -> Void) -> MeroTheme {
        var copy = self
        change(&copy)
        return copy
    }
}

/// The default theme. (== mero-react `defaultMeroTheme`.)
public var defaultMeroTheme: MeroTheme { .calimero }

extension Color {
    /// A colour from `0xRRGGBB`.
    public init(meroHex rgb: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255, opacity: opacity)
    }
}

private struct MeroThemeKey: EnvironmentKey {
    static var defaultValue: MeroTheme { .calimero }
}

extension EnvironmentValues {
    /// The ``MeroTheme`` MeroKitUI views draw with.
    public var meroTheme: MeroTheme {
        get { self[MeroThemeKey.self] }
        set { self[MeroThemeKey.self] = newValue }
    }
}

extension View {
    /// Draw MeroKitUI views below with `theme`.
    public func meroTheme(_ theme: MeroTheme) -> some View {
        environment(\.meroTheme, theme)
    }
}
#endif
