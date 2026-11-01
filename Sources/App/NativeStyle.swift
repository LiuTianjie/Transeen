import SwiftUI
import AppKit

/// Opaque neutral surfaces shared by settings windows, sheets, and popovers.
/// System materials can pick up wallpaper tint, so they are not used here.
enum SettingsAppearance {
    static var canvasColor: NSColor { neutral(light: 1, dark: 32 / 255) }
    static var canvas: Color { Color(nsColor: canvasColor) }
    static var panel: Color { Color(nsColor: neutral(light: 247 / 255, dark: 40 / 255)) }
    static var sidebar: Color { Color(nsColor: neutral(light: 249 / 255, dark: 36 / 255)) }
    static var border: Color { Color.primary.opacity(0.075) }

    private static func neutral(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
        }
    }
}

extension View {
    func settingsSurface() -> some View {
        background(SettingsAppearance.canvas.ignoresSafeArea())
            .presentationBackground(SettingsAppearance.canvas)
    }

    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .backgroundStyle(SettingsAppearance.panel)
            .background(SettingsAppearance.canvas)
    }
}

enum TilePalette {
    static let blue = [Color(red: 0.30, green: 0.58, blue: 1.0), Color(red: 0.12, green: 0.38, blue: 0.92)]
    static let orange = [Color(red: 1.0, green: 0.66, blue: 0.22), Color(red: 0.97, green: 0.47, blue: 0.10)]
    static let purple = [Color(red: 0.76, green: 0.48, blue: 1.0), Color(red: 0.55, green: 0.30, blue: 0.92)]
    static let red = [Color(red: 1.0, green: 0.42, blue: 0.40), Color(red: 0.92, green: 0.20, blue: 0.22)]
    static let yellow = [Color(red: 1.0, green: 0.80, blue: 0.20), Color(red: 0.98, green: 0.62, blue: 0.05)]
    static let indigo = [Color(red: 0.42, green: 0.45, blue: 1.0), Color(red: 0.28, green: 0.28, blue: 0.86)]
    static let gray = [Color(white: 0.62), Color(white: 0.45)]
    static let graphite = [Color(white: 0.36), Color(white: 0.18)]
}

/// A white SF Symbol on a gradient squircle, as System Settings draws its panes.
struct IconTile: View {
    var symbol: String
    var colors: [Color]
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// A shortcut such as "⌥⇧T" drawn as one key cap per modifier plus one for the key.
struct KeyCaps: View {
    let keys: [String]

    init(_ display: String) {
        var keys: [String] = []
        var rest = ""
        for character in display {
            if rest.isEmpty, "⌘⌥⌃⇧".contains(character) { keys.append(String(character)) } else { rest.append(character) }
        }
        if !rest.isEmpty { keys.append(rest) }
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, key.count > 1 ? 5 : 0)
                    .frame(minWidth: 19, minHeight: 19)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined())
    }
}

/// A rounded group like a grouped Form section, for layouts that are not a Form.
struct CardGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(4)
            .background(SettingsAppearance.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SettingsAppearance.border, lineWidth: 0.5))
    }
}
