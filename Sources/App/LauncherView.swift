import SwiftUI
import AppKit

struct LauncherView: View {
    @Bindable var settings: AppSettings
    @Bindable var permission: ScreenPermission
    var start: (CaptureMode) -> Void
    var showSettings: () -> Void
    var showPermission: () -> Void
    var openImage: () -> Void
    var closeCapture: () -> Void
    var quit: () -> Void
    var showLicense: () -> Void
    var checkForUpdates: () -> Void
    @ObservedObject var license: LicenseManager
    var compact = false

    private var alternateMode: CaptureMode { settings.defaultMode == .translate ? .screenshot : .translate }
    private var sourceLanguage: Binding<String> {
        Binding(get: { settings.detectsSource ? "auto" : settings.source.rawValue }, set: { value in
            settings.detectsSource = value == "auto"
            if let language = AppLanguage(rawValue: value) { settings.source = language }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Transeen").font(.headline)
                Spacer()
                Button("设置", systemImage: "gearshape", action: showSettings)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(settings.shortcuts.help("设置", .settings)).accessibilityLabel("设置")
            }

            VStack(alignment: .leading, spacing: 10) {
                Button { start(settings.defaultMode) } label: {
                    HStack(spacing: 8) {
                        Label(settings.defaultMode == .translate ? "截图翻译" : "开始截图",
                              systemImage: settings.defaultMode == .translate ? "translate" : "viewfinder")
                        Spacer(minLength: 0)
                        if let shortcut = settings.shortcuts.binding(.captureDefault)?.display {
                            Text(shortcut).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large)

                Text(settings.defaultMode == .translate ? "框选一块区域，译文留在原处" : "框选一块区域，标注或复制")
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button { start(alternateMode) } label: {
                        Label(alternateMode == .screenshot ? "截图标注" : "截图翻译",
                              systemImage: alternateMode == .screenshot ? "pencil.and.outline" : "translate")
                            .frame(maxWidth: .infinity)
                    }
                    Button(action: openImage) {
                        Label("打开图片…", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                    }.help(settings.shortcuts.help("打开本地图片", .openImage))
                }.buttonStyle(.bordered)
            }

            Button(license.state.isActivated ? "已激活 · 授权与账号" : "激活 Transeen", systemImage: license.state.isActivated ? "checkmark.seal" : "key", action: showLicense)
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文").font(.caption).foregroundStyle(.secondary)
                    Picker("原文语言", selection: sourceLanguage) {
                        Text("自动识别").tag("auto")
                        Divider()
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }.labelsHidden().pickerStyle(.menu)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.bottom, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("译文").font(.caption).foregroundStyle(.secondary)
                    Picker("译文语言", selection: $settings.target) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }.labelsHidden().pickerStyle(.menu)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            if !permission.granted {
                Button("开启屏幕录制权限…", systemImage: "rectangle.dashed.badge.record", action: showPermission)
                    .buttonStyle(.bordered)
            }

            Divider()

            HStack(spacing: 8) {
                Button(action: showSettings) {
                    Label(settings.useModel ? (settings.model.isEmpty ? "设置翻译模型" : settings.model) : "Apple 本机翻译",
                          systemImage: settings.useModel ? "network" : "desktopcomputer")
                        .font(.caption).lineLimit(1)
                }.buttonStyle(.borderless).foregroundStyle(.secondary).help("选择翻译服务")
                Spacer(minLength: 4)
                Menu {
                    Button("关闭当前截图", action: closeCapture)
                    Button("屏幕权限…", action: showPermission)
                    Divider()
                    Button("激活与账号…", action: showLicense)
                    Button("检查更新…", action: checkForUpdates)
                    Divider()
                    Button("退出 Transeen", action: quit)
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("更多操作")
            }
        }
        .padding(compact ? 16 : 20)
        .frame(width: compact ? 320 : 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { permission.refresh() }
    }
}
