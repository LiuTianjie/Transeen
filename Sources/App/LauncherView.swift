import SwiftUI
import AppKit

struct LauncherView: View {
    @Bindable var settings: AppSettings
    @Bindable var permission: ScreenPermission
    var start: (CaptureMode) -> Void
    var showSettings: () -> Void
    var showPermission: () -> Void
    var showOnboarding: () -> Void
    var openImage: () -> Void
    var closeCapture: () -> Void
    var quit: () -> Void
    var showLicense: () -> Void
    var checkForUpdates: () -> Void
    @ObservedObject var license: LicenseManager
    var compact = false

    private var sourceLanguage: Binding<String> {
        Binding(get: { settings.detectsSource ? "auto" : settings.source.rawValue }, set: { value in
            settings.detectsSource = value == "auto"
            if let language = AppLanguage(rawValue: value) { settings.source = language }
        })
    }

    private var serviceTitle: String {
        switch settings.service {
        case .apple: L("Apple 本机翻译")
        case .local: settings.selectedLocalModel.name
        case .remote: settings.model.isEmpty ? L("设置翻译模型") : settings.model
        }
    }
    private var serviceIcon: String {
        switch settings.service {
        case .apple: "desktopcomputer"
        case .local: "cpu"
        case .remote: "network"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transeen").font(.system(size: 13, weight: .semibold))
                    Button(action: showLicense) {
                        Text(license.state.isActivated ? L("已激活 · 授权与账号") : L("激活 Transeen"))
                            .font(.system(size: 11)).foregroundStyle(license.state.isActivated ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button(L("设置"), systemImage: "gearshape", action: showSettings)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
                    .help(settings.shortcuts.help(L("设置"), .settings)).accessibilityLabel(L("设置"))
            }.padding(.horizontal, 6)

            VStack(spacing: 2) {
                LauncherRow(symbol: "character.bubble.fill", colors: TilePalette.blue, title: L("截图翻译"), detail: L("框选一块区域，译文留在原处"),
                            shortcut: settings.shortcuts.binding(.captureTranslate)?.display) { start(.translate) }
                LauncherRow(symbol: "pencil.tip.crop.circle.fill", colors: TilePalette.orange, title: L("截图标注"), detail: L("框选后标注，不翻译"),
                            shortcut: settings.shortcuts.binding(.captureScreenshot)?.display) { start(.screenshot) }
                LauncherRow(symbol: "photo.fill", colors: TilePalette.purple, title: L("打开图片…"), detail: L("打开本地图片"),
                            shortcut: settings.shortcuts.binding(.openImage)?.display, action: openImage)
                if !permission.granted {
                    LauncherRow(symbol: "exclamationmark.triangle.fill", colors: TilePalette.yellow, title: L("开启屏幕录制权限…"), detail: L("屏幕权限尚未开启"),
                                shortcut: nil, action: showPermission)
                }
            }

            CardGroup {
                HStack(spacing: 8) {
                    Picker(L("原文语言"), selection: sourceLanguage) {
                        Text(L("自动识别")).tag("auto")
                        Divider()
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }.labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Picker(L("译文语言"), selection: $settings.target) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }.labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(.horizontal, 8).padding(.vertical, 6)
                Divider().padding(.horizontal, 8)
                Button(action: showSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: serviceIcon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                        Text(serviceTitle).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("选择翻译服务"))
            }

            HStack {
                Spacer()
                Menu {
                    Button(L("关闭当前截图"), action: closeCapture)
                    Button(L("屏幕权限…"), action: showPermission)
                    Button(L("新手引导…"), action: showOnboarding)
                    Divider()
                    Button(L("激活与账号…"), action: showLicense)
                    Button(L("检查更新…"), action: checkForUpdates)
                    Divider()
                    Button(L("退出 Transeen"), action: quit)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("更多操作"))
            }.padding(.horizontal, 6)
        }
        .padding(compact ? 10 : 14)
        .padding(.top, compact ? 0 : 6)
        .frame(width: compact ? 320 : 340)
        .background { if !compact { VisualEffectBackground(material: .popover).ignoresSafeArea() } }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { permission.refresh() }
    }
}

private struct LauncherRow: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let detail: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, colors: colors, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let shortcut { KeyCaps(shortcut) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
