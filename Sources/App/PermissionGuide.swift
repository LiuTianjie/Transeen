import AppKit
import SwiftUI

@MainActor @Observable
final class ScreenPermission {
    private(set) var granted = CGPreflightScreenCaptureAccess()
    private(set) var requested = UserDefaults.standard.bool(forKey: "screenPermissionRequested")
    var pendingMode: CaptureMode? {
        didSet { UserDefaults.standard.set(pendingMode?.rawValue, forKey: "pendingCaptureMode") }
    }
    init() {
        pendingMode = UserDefaults.standard.string(forKey: "pendingCaptureMode").flatMap(CaptureMode.init(rawValue:))
    }
    func refresh() { granted = CGPreflightScreenCaptureAccess() }
    func openSettings() {
        if !requested {
            requested = true
            UserDefaults.standard.set(true, forKey: "screenPermissionRequested")
            _ = CGRequestScreenCaptureAccess()
            refresh()
        }
        if !granted { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    }
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6\n/usr/bin/open -n \"$1\"", "transeen-relaunch", Bundle.main.bundlePath]
        do { try task.run(); NSApp.terminate(nil) } catch { /* The explicit manual instructions stay visible. */ }
    }
}

/// A small native utility window. The sample is interactive, but no permission is
/// requested until the user chooses the system-settings action.
struct PermissionGuide: View {
    @Bindable var permission: ScreenPermission
    var continueCapture: () -> Void
    var later: () -> Void
    @State private var peeking = false
    @State private var helpVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable().interpolation(.high).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transeen").font(.system(size: 23, weight: .medium, design: .rounded)).tracking(-0.4)
                    Text(L("截图与原位翻译")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.bottom, 24)

            preview
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(peeking ? Color.secondary.opacity(0.5) : Color.accentColor).frame(width: 4, height: 4)
                    Text(peeking ? L("原文") : L("译文")).foregroundStyle(.secondary)
                }.font(.system(size: 10))
                Spacer()
                HoldToCompare(peeking: $peeking).frame(width: 91, height: 20)
            }.padding(.top, 12).padding(.bottom, 23)

            Divider()
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: permission.granted ? "checkmark.circle.fill" : "macwindow")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(permission.granted ? Color.green : Color.secondary)
                    .frame(width: 27).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(permission.granted ? L("已准备好") : L("还差一步：允许截屏"))
                        .font(.system(size: 13, weight: .medium))
                    Text(permission.granted ? L("选一块屏幕，就能开始。") : L("在系统设置中开启 Transeen 的屏幕录制权限。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !permission.granted {
                    Button { helpVisible.toggle() } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
                    }.buttonStyle(.borderless).help(L("查看授权步骤"))
                        .popover(isPresented: $helpVisible, arrowEdge: .trailing) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L("开启屏幕录制")).font(.system(size: 13, weight: .semibold))
                                Text(L("系统设置 → 隐私与安全性\n→ 屏幕与系统音频录制"))
                                Text(L("找到 Transeen，开启开关。\n返回这里后会自动检查。"))
                                Text(L("仅使用屏幕图像，不采集音频。"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                if permission.requested {
                                    Divider()
                                    Text(L("已经开启，但仍未生效？")).foregroundStyle(.secondary)
                                    HStack {
                                        Button(L("重新检查")) { permission.refresh() }
                                        Button(L("重新打开")) { permission.relaunch() }
                                    }.controlSize(.small)
                                }
                            }.font(.system(size: 12)).lineSpacing(3).padding(18).frame(width: 285, alignment: .leading)
                        }
                }
            }.padding(.vertical, 20)
            HStack {
                Button(L("稍后"), action: later).keyboardShortcut(.cancelAction)
                Spacer()
                Button(permission.granted ? L("开始框选") : L("打开系统设置…"), action: permission.granted ? continueCapture : permission.openSettings)
                    .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }.controlSize(.regular)
        }
        .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 24)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                permission.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permission.refresh() }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(Color.primary.opacity(0.10)).frame(width: 5, height: 5) }
                Spacer()
                Text(L("翻译预览")).font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 17).padding(.top, 13).padding(.bottom, 6)
            previewRow("sun.max", peeking ? "Appearance" : L("外观"), peeking ? "Light" : L("浅色"))
            Divider().padding(.leading, 44).padding(.trailing, 16)
            previewRow("bell", peeking ? "Notifications" : L("通知"), peeking ? "On" : L("开启"))
            Divider().padding(.leading, 44).padding(.trailing, 16)
            previewRow("command", peeking ? "Keyboard shortcuts" : L("键盘快捷键"), "⌘ K")
                .padding(.bottom, 7)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 0.5))
        .overlay {
            ViewfinderCorners()
                .stroke(permission.granted ? Color.green.opacity(0.55) : Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                .padding(permission.granted ? -3 : -6)
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: permission.granted)
        }
        .accessibilityElement(children: .combine)
    }
    private func previewRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .medium)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 15).frame(height: 38)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: peeking)
    }
}

private struct ViewfinderCorners: Shape {
    func path(in r: CGRect) -> Path {
        let rect = r.insetBy(dx: 0.75, dy: 0.75)
        let length: CGFloat = 13
        var path = Path()
        for (x, y, sx, sy) in [(rect.minX, rect.minY, CGFloat(1), CGFloat(1)),
                                (rect.maxX, rect.minY, -1, 1), (rect.minX, rect.maxY, 1, -1), (rect.maxX, rect.maxY, -1, -1)] {
            path.move(to: CGPoint(x: x, y: y + sy * length))
            path.addLine(to: CGPoint(x: x, y: y + sy * 5))
            path.addQuadCurve(to: CGPoint(x: x + sx * 5, y: y), control: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + sx * length, y: y))
        }
        return path
    }
}

/// NSButton supplies native tracking/hover. Translation reappears on mouse-up,
/// including when the pointer leaves the button during the hold.
private struct HoldToCompare: NSViewRepresentable {
    @Binding var peeking: Bool
    func makeNSView(context: Context) -> CompareButton {
        let button = CompareButton(title: L("按住看原文"), target: nil, action: nil)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(L("对照示例原文"))
        button.setAccessibilityHelp(L("按住显示英文，松开显示中文"))
        return button
    }
    func updateNSView(_ view: CompareButton, context: Context) { view.onPeek = { peeking = $0 } }
}
private final class CompareButton: NSButton {
    var onPeek: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onPeek?(true)
        super.mouseDown(with: event)
        onPeek?(false)
    }
    override func accessibilityPerformPress() -> Bool {
        onPeek?(true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2)); self?.onPeek?(false)
        }
        return true
    }
}
