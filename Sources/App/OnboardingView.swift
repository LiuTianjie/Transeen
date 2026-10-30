import AppKit
import SwiftUI

/// First-run checklist: everything a capture needs is prepared here, so the
/// first capture neither stops for activation or permission nor waits for a download.
struct OnboardingView: View {
    @Bindable var settings: AppSettings
    @Bindable var permission: ScreenPermission
    @ObservedObject var license: LicenseManager
    var showLicense: () -> Void
    var finish: (_ startCapture: Bool) -> Void
    @State private var packs = LanguagePacks()

    private var translationReady: Bool {
        switch settings.service {
        case .remote: return (try? ModelConfiguration(endpoint: settings.endpoint, model: settings.model)) != nil
        case .local: return LocalModelStore.shared.status(settings.selectedLocalModel) == .installed
        case .apple: return packs.sources.isEmpty || packs.installedCount > 0
        }
    }
    private var translationDetail: String {
        if settings.service == .remote { return translationReady ? L("已填写模型接口，可先测试连接") : L("填写 chat/completions 接口地址和模型名称") }
        if settings.service == .local { return translationReady ? L("%@ 已下载，可离线翻译", settings.selectedLocalModel.name) : L("下载一个本地模型（约 1.1 GB），之后完全离线翻译") }
        if packs.sources.isEmpty { return L("这对语言不需要下载") }
        if packs.installedCount == 0 { return L("先下载要翻译的语言，第一次截图就不用等") }
        return L("已下载 %ld/%ld 个语言包，需要时再补充", packs.installedCount, packs.sources.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 64, height: 64).accessibilityHidden(true)
                Text(L("欢迎使用 Transeen")).font(.system(size: 22, weight: .bold))
                Text(L("先把这几项准备好，用的时候就不用等。")).font(.system(size: 13)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.top, 34).padding(.bottom, 2)

            Form {
                Section {
                    SetupStep(number: 1, symbol: "globe", colors: TilePalette.blue, title: L("你的母语"), detail: L("识别出的文字默认翻译成它；本来就是它的，翻译成%@", settings.target.alternate.displayName), done: true) {
                        Picker(L("母语"), selection: $settings.target) {
                            ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
                Section {
                    SetupStep(number: 2, symbol: "key.fill", colors: TilePalette.yellow, title: L("激活 Transeen"), detail: license.state.isActivated ? L("截图、标注与翻译已解锁") : L("需要 TR- 激活码，无需登录"), done: license.state.isActivated) {
                        if license.state == .checking { ProgressView().controlSize(.small) }
                        else if !license.state.isActivated { Button(L("输入激活码…"), action: showLicense) }
                    }
                }
                Section {
                    SetupStep(number: 3, symbol: "record.circle", colors: TilePalette.red, title: L("允许录制屏幕"), detail: permission.granted ? L("已开启") : permission.requested ? L("已开启但仍未生效时，重新打开 Transeen") : L("只读取屏幕图像，不采集音频"), done: permission.granted) {
                        if !permission.granted {
                            HStack {
                                if permission.requested { Button(L("重新打开")) { permission.relaunch() } }
                                Button(L("打开系统设置…")) { permission.openSettings() }
                            }
                        }
                    }
                }
                Section {
                    SetupStep(number: 4, symbol: "character.bubble.fill", colors: TilePalette.indigo, title: L("准备翻译"), detail: translationDetail, done: translationReady) { EmptyView() }
                    TranslationServiceFields(settings: settings, packs: packs)
                }
                Section {
                    SetupStep(number: 5, symbol: "command", colors: TilePalette.graphite, title: L("确认快捷键"), detail: L("按下即框选；松开后拖动结果边缘可调整范围"), done: settings.shortcuts.binding(.captureTranslate) != nil || settings.shortcuts.binding(.captureScreenshot) != nil) { EmptyView() }
                    ShortcutRow(shortcuts: settings.shortcuts, action: .captureTranslate)
                    ShortcutRow(shortcuts: settings.shortcuts, action: .captureScreenshot)
                    if !settings.shortcuts.message.isEmpty { Text(settings.shortcuts.message).font(.caption).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button(L("稍后")) { finish(false) }.keyboardShortcut(.cancelAction)
                Text(L("可随时从菜单栏打开「新手引导…」")).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(L("开始截图翻译")) { finish(true) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.controlSize(.large).padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(minWidth: 540, maxWidth: .infinity, minHeight: 680, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .languagePacks(packs, for: settings)
        .task {
            while !Task.isCancelled {
                permission.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onDisappear { settings.shortcuts.recording = nil }
    }
}

private struct SetupStep<Trailing: View>: View {
    let number: Int
    let symbol: String
    let colors: [Color]
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var trailing: Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, colors: colors, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
            if done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity)).accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: done)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("第 %ld 步：%@，%@", number, title, done ? L("已完成") : detail))
    }
}
