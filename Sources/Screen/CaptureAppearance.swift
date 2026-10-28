import AppKit
import SwiftUI

/// Opaque, appearance-aware surfaces; desktop pixels never determine contrast.
enum CaptureAppearance {
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let foreground = Color.primary
    static let secondary = Color.secondary
    static let accent = Color.accentColor
    static let quick = Animation.easeOut(duration: 0.14)
    static let settle = Animation.spring(response: 0.26, dampingFraction: 0.88)
}

struct CaptureSurface: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(CaptureAppearance.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.055), .clear], startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(CaptureAppearance.foreground.opacity(contrast == .increased ? 0.65 : 0.20), lineWidth: 0.75)
                    }
            }
            .foregroundStyle(CaptureAppearance.foreground)
            .tint(CaptureAppearance.accent)
            .environment(\.controlActiveState, .key)
    }
}

/// One hit target and one visual language for every toolbar control.
struct CaptureToolbarButtonStyle: ButtonStyle {
    var selected = false
    var neutralSelection = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? (selected && !neutralSelection ? CaptureAppearance.accent : CaptureAppearance.foreground) : CaptureAppearance.secondary.opacity(0.4))
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected && !neutralSelection ? CaptureAppearance.accent.opacity(0.11) : CaptureAppearance.foreground.opacity(configuration.isPressed && enabled ? 0.12 : selected ? 0.065 : hovering && enabled ? 0.045 : 0))
            }
            .overlay {
                if focused { RoundedRectangle(cornerRadius: 6).strokeBorder(CaptureAppearance.accent, lineWidth: 1.5) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : CaptureAppearance.quick, value: hovering)
    }
}
