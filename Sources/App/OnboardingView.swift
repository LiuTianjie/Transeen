import AppKit
import SwiftUI
@preconcurrency import Translation

/// A short, resumable path from a safe sample to the first real capture.
/// Advanced service configuration stays in the existing settings form.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case experience, language, permission, capture
        var title: String {
            switch self {
            case .experience: L("先试一下")
            case .language: L("阅读语言")
            case .permission: L("准备截屏")
            case .capture: L("开始使用")
            }
        }
    }

    @Bindable var settings: AppSettings
    @Bindable var permission: ScreenPermission
    @ObservedObject var license: LicenseManager
    var stepChanged: (Int) -> Void
    var finish: (CaptureMode?) -> Void
    @State private var step: Step
    @State private var sampleSource: AppLanguage
    @State private var packs = LanguagePacks()
    @State private var showsServiceSettings = false
    @State private var showsActivation = false
    @State private var showsShortcutSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(settings: AppSettings, permission: ScreenPermission, license: LicenseManager,
         initialStep: Int = 0, stepChanged: @escaping (Int) -> Void = { _ in },
         finish: @escaping (CaptureMode?) -> Void) {
        self.settings = settings
        self.permission = permission
        self.license = license
        self.stepChanged = stepChanged
        self.finish = finish
        _step = State(initialValue: Step(rawValue: initialStep) ?? .experience)
        _sampleSource = State(initialValue: settings.source == settings.target ? settings.target.alternate : settings.source)
    }

    private var captureReady: Bool { license.state.isActivated && permission.granted }
    private var needsLanguagePack: Bool { !LanguagePacks.sources(for: settings.target, source: sampleSource).isEmpty }
    private var translationReady: Bool {
        switch settings.service {
        case .apple: !needsLanguagePack || packs.statuses[sampleSource] == .installed
        case .local: LocalModelStore.shared.status(settings.selectedLocalModel) == .installed
        case .remote: (try? ModelConfiguration(endpoint: settings.endpoint, model: settings.model)) != nil
        }
    }
    private var serviceName: String {
        switch settings.service {
        case .apple: L("Apple 本机翻译")
        case .local: settings.selectedLocalModel.name
        case .remote: L("大模型接口")
        }
    }
    private var primaryTitle: String {
        if step == .permission || step == .capture {
            if !license.state.isActivated { return L("激活 Transeen") }
            if !permission.granted { return L("允许截屏") }
        }
        if step == .capture { return translationReady ? L("开始截图翻译") : L("先试试截图标注") }
        return L("继续")
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch step {
                        case .experience: experience
                        case .language: language
                        case .permission: permissions
                        case .capture: firstCapture
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, OnboardingLayout.inset)
                    .padding(.top, 48).padding(.bottom, 24)
                    .id(step)
                    .transition(.opacity)
                }
                .scrollIndicators(.hidden)
                footer
            }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .settingsSurface()
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: step)
        .onChange(of: step) { _, value in
            settings.shortcuts.recording = nil
            stepChanged(value.rawValue)
        }
        .onChange(of: settings.target) { _, target in
            if sampleSource == target { sampleSource = target.alternate }
        }
        .onChange(of: sampleSource) { _, source in
            settings.source = source
        }
        .translationTask(packs.configuration) { session in await packs.handle(session) }
        .task(id: "\(sampleSource.rawValue)-\(settings.target.rawValue)-\(settings.service.rawValue)") {
            if settings.service == .apple { await packs.refresh(source: sampleSource, target: settings.target) }
        }
        .task {
            while !Task.isCancelled {
                permission.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
            if settings.service == .apple {
                Task { await packs.refresh(source: sampleSource, target: settings.target) }
            }
        }
        .sheet(isPresented: $showsActivation) {
            LicenseView(manager: license) { showsActivation = false }
        }
        .sheet(isPresented: $showsServiceSettings, onDismiss: {
            if !settings.detectsSource { sampleSource = settings.source }
            Task { await packs.refresh(source: sampleSource, target: settings.target) }
        }) {
            OnboardingServiceSettings(settings: settings) { showsServiceSettings = false }
        }
        .sheet(isPresented: $showsShortcutSettings) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("确认快捷键")).font(.title3.weight(.semibold))
                ShortcutRow(shortcuts: settings.shortcuts, action: .captureTranslate)
                ShortcutRow(shortcuts: settings.shortcuts, action: .captureScreenshot)
                if !settings.shortcuts.message.isEmpty {
                    Text(settings.shortcuts.message).font(.callout).foregroundStyle(.secondary)
                }
                if settings.shortcuts.recording != nil {
                    Button(L("取消录制")) { settings.shortcuts.recording = nil }
                }
                HStack { Spacer(); Button(L("完成")) { showsShortcutSettings = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 460).settingsSurface()
                .onDisappear { settings.shortcuts.recording = nil }
        }
        .onDisappear { settings.shortcuts.recording = nil }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 30, height: 30).accessibilityHidden(true)
                Text("Transeen").font(.system(size: 15, weight: .semibold)).tracking(-0.2)
            }
            .padding(.bottom, 42)
            VStack(spacing: 8) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", item.rawValue + 1))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(item == step ? Color.accentColor : Color.secondary)
                            .frame(width: 24, height: 24)
                            .background(item == step ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        Text(item.title).font(.system(size: 12, weight: item == step ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(item == step ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 42)
                    .background(item == step ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(item == step ? .isSelected : [])
                }
            }.padding(.horizontal, -10)
            Spacer(minLength: 28)
            Button(L("稍后再设置")) { finish(nil) }
                .buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24).padding(.top, 46).padding(.bottom, 25)
        .frame(width: 184)
        .background(SettingsAppearance.sidebar)
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
    }

    private var experience: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(L("让译文，留在原处。"), L("不用复制粘贴，也不必离开正在阅读的页面。"))
            OnboardingSample(target: settings.target)
            HStack(spacing: 6) {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
                Text(L("这是一段演示内容，不会读取你的屏幕。"))
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 16)
        }
    }

    private var language: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(L("用你熟悉的语言阅读。"), L("默认使用系统语言，也可以随时更改。"))
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    OnboardingRowIcon(symbol: "character.bubble")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("翻译成")).font(.system(size: 13, weight: .medium))
                        Text(L("同时用于 Transeen 的界面语言")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker(L("母语"), selection: $settings.target) {
                        ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                    }.labelsHidden().fixedSize().frame(width: 144, alignment: .trailing).disabled(packs.isDownloading)
                }
                Divider().padding(.vertical, 20)
                HStack(alignment: .center, spacing: 12) {
                    OnboardingRowIcon(symbol: settings.service == .remote ? "network" : "desktopcomputer")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(serviceName).font(.system(size: 13, weight: .medium))
                        Text(settings.service == .remote ? L("只发送识别后的文字，不上传截图。") : L("翻译在这台 Mac 上完成。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(L("更改…")) { showsServiceSettings = true }.controlSize(.small).disabled(packs.isDownloading)
                }
                if settings.service == .apple {
                    Divider().padding(.vertical, 20)
                    HStack(spacing: 12) {
                        OnboardingRowIcon(symbol: "book.closed")
                        Text(L("常读的语言")).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 12)
                        Picker(L("常读的语言"), selection: $sampleSource) {
                            ForEach(AppLanguage.allCases.filter { $0 != settings.target }) { Text($0.displayName).tag($0) }
                        }.labelsHidden().fixedSize().frame(width: 144, alignment: .trailing).disabled(packs.isDownloading)
                    }
                    HStack { Spacer(); languagePackAction.font(.system(size: 11)).controlSize(.small) }.padding(.top, 14)
                    if let message = packs.message {
                        Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    }
                } else if !translationReady {
                    HStack { Spacer(); Button(L("准备翻译")) { showsServiceSettings = true } }.padding(.top, 14)
                }
            }.onboardingPanel()
            if !translationReady {
                OnboardingNote(symbol: "info.circle", text: L("不用等下载完成，也可以先体验截图和标注。")).padding(.top, 18)
            }
        }
    }

    @ViewBuilder private var languagePackAction: some View {
        if !needsLanguagePack {
            Label(L("已准备好"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            switch packs.statuses[sampleSource] ?? .checking {
            case .installed:
                Label(L("已下载"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .checking:
                ProgressView().controlSize(.small)
            case .downloading:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("下载中…")) }.foregroundStyle(.secondary)
            case .missing:
                Button(L("下载语言包")) { packs.download(sampleSource) }.disabled(packs.isDownloading)
            case .unsupported:
                Text(L("系统暂不支持")).foregroundStyle(.secondary)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(L("只在你截图时，读取屏幕。"), L("macOS 需要你允许屏幕录制，才能截取选中的画面。Transeen 不采集音频。"))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    OnboardingRowIcon(symbol: "macwindow")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(permission.granted ? L("屏幕权限已开启") : L("允许截屏")).font(.system(size: 13, weight: .medium))
                        Text(permission.granted ? L("已准备好读取你选择的画面。") : L("系统设置 → 隐私与安全性 → 屏幕与系统音频录制"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if permission.granted { readyMark }
                }
                if !permission.granted {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("找到 Transeen，打开开关，再回到这里。进度会为你保留。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button(L("打开系统设置…")) { permission.openSettings() }
                            if permission.requested {
                                Button(L("重新检查")) { permission.refresh() }
                                Button(L("重新打开")) { permission.relaunch() }
                            }
                        }.controlSize(.small)
                    }.padding(.leading, 44).padding(.top, 16)
                }
                Divider().padding(.vertical, 20)
                HStack(spacing: 12) {
                    OnboardingRowIcon(symbol: "key")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(license.state.isActivated ? L("Transeen 已激活") : L("实际截图需要激活 Transeen"))
                            .font(.system(size: 13, weight: .medium))
                        Text(license.state.isActivated ? L("截图、标注与翻译已解锁") : L("需要 TR- 激活码，无需登录"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if license.state.isActivated { readyMark }
                    else if license.state == .checking { ProgressView().controlSize(.small).frame(width: 20) }
                    else { Button(L("输入激活码…")) { showsActivation = true }.controlSize(.small) }
                }
                if case .unavailable(let reason) = license.state {
                    Text(reason).font(.caption).foregroundStyle(.orange).padding(.top, 12).padding(.leading, 44)
                }
            }.onboardingPanel()
            if permission.requested && !permission.granted {
                OnboardingNote(symbol: "arrow.clockwise", text: L("已打开开关但仍未生效？重新打开 Transeen 后会回到这一步。"))
                    .padding(.top, 18)
            }
        }
    }

    private var readyMark: some View {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
            .foregroundStyle(Color.green).frame(width: 20).accessibilityLabel(L("已准备好"))
    }

    private var firstCapture: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(L("下一次，只需一个快捷键。"), L("Transeen 会留在菜单栏，随时等你框选。"))
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(L("菜单栏")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "viewfinder").font(.system(size: 12, weight: .medium))
                        .overlay { Image(systemName: "equal").font(.system(size: 5, weight: .semibold)) }
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 26, height: 22)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Image(systemName: "battery.100percent").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text("9:41").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 20).padding(.vertical, 11)
                Divider()
                HStack(alignment: .center, spacing: 24) {
                    Text(settings.shortcuts.binding(.captureTranslate)?.display ?? L("菜单栏"))
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .frame(width: 110, height: 88)
                        .background(SettingsAppearance.canvas, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("截图翻译")).font(.system(size: 14, weight: .semibold))
                        Text(settings.shortcuts.binding(.captureTranslate) == nil ? L("点击菜单栏图标，选择截图翻译。") : L("按快捷键 → 拖动框选 → 原处读译文"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(L("更改快捷键…")) { showsShortcutSettings = true }.buttonStyle(.link).font(.system(size: 11))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(20)
                if settings.shortcuts.binding(.captureTranslate)?.keyCode == 122 {
                    Divider().padding(.horizontal, 20)
                    Text(L("笔记本可能需要按 Fn–F1。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
                }
            }.background(OnboardingLayout.surface, in: RoundedRectangle(cornerRadius: OnboardingLayout.radius))
                .overlay(RoundedRectangle(cornerRadius: OnboardingLayout.radius).strokeBorder(OnboardingLayout.border))
            OnboardingNote(symbol: translationReady ? "cursorarrow.click" : "info.circle", text: translationReady ? L("点击下面的按钮，选一块带文字的区域。按 Esc 可以退出。") : L("翻译还没准备好，先截一张图试试标注。语言包和模型可以稍后在设置中补齐。"))
                .padding(.top, 18)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button { step = Step(rawValue: step.rawValue - 1) ?? .experience } label: {
                    Label(L("返回"), systemImage: "chevron.left").font(.system(size: 12))
                }.buttonStyle(.borderless).disabled(step == .experience).opacity(step == .experience ? 0 : 1)
                Spacer()
                Button(action: advance) {
                    HStack(spacing: 8) {
                        Text(primaryTitle)
                        Image(systemName: step == .capture && captureReady ? "viewfinder" : "arrow.right")
                    }.frame(minWidth: 96).padding(.horizontal, 4)
                }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled((step == .permission || step == .capture) && license.state == .checking)
            }.padding(.vertical, 20)
        }.padding(.horizontal, OnboardingLayout.inset)
    }

    private func advance() {
        if step == .permission || step == .capture {
            guard license.state.isActivated else { showsActivation = true; return }
            permission.refresh()
            guard permission.granted else { permission.openSettings(); return }
        }
        if step == .capture { finish(translationReady ? .translate : .screenshot) }
        else { step = Step(rawValue: step.rawValue + 1) ?? .capture }
    }
}

private enum OnboardingLayout {
    static let inset: CGFloat = 32
    static let radius: CGFloat = 12
    static var surface: Color { SettingsAppearance.panel }
    static var border: Color { SettingsAppearance.border }
}

private extension View {
    func onboardingPanel() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingLayout.surface, in: RoundedRectangle(cornerRadius: OnboardingLayout.radius))
            .overlay(RoundedRectangle(cornerRadius: OnboardingLayout.radius).strokeBorder(OnboardingLayout.border))
    }
}

private struct OnboardingRowIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

private struct OnboardingNote: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).frame(width: 12).padding(.top, 1).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }.font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingServiceSettings: View {
    @Bindable var settings: AppSettings
    var done: () -> Void
    @State private var packs = LanguagePacks()
    var body: some View {
        VStack(spacing: 0) {
            Form { Section(L("准备翻译")) { TranslationServiceFields(settings: settings, packs: packs) } }
                .settingsForm()
            HStack { Spacer(); Button(L("完成"), action: done).keyboardShortcut(.defaultAction) }.padding(20)
        }.frame(width: 570, height: 520).settingsSurface().languagePacks(packs, for: settings)
    }
}

/// Fixed example copy, intentionally independent of capture, OCR, and licensing.
/// A drag teaches selection; the button provides a keyboard/VoiceOver alternative.
private struct OnboardingSample: View {
    let target: AppLanguage
    @State private var translated = false
    @State private var hasTried = false
    @State private var selection: CGRect?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in Circle().fill(Color.primary.opacity(0.12)).frame(width: 7, height: 7) }
                Spacer()
                Text(L("阅读示例")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 13) {
                Text(translated ? L("让阅读回到内容本身。") : (target == .en ? "読むことに、集中しよう。" : "A quieter way to read."))
                    .font(.system(size: 23, weight: .medium, design: .serif)).tracking(-0.35)
                    .fixedSize(horizontal: false, vertical: true)
                Text(translated ? L("框选你想读的内容，不必离开当前页面。") : (target == .en ? "読みたいところを選択。その場で翻訳。" : "Select what matters. Keep your place."))
                    .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 200, height: 4)
                Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 148, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color.primary.opacity(translated ? 0.02 : 0))
            .contentShape(Rectangle())
            .overlay {
                if let selection {
                    Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .background(Color.accentColor.opacity(0.06))
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    selection = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                       width: abs(value.translation.width), height: abs(value.translation.height))
                }
                .onEnded { _ in
                    if let selection, selection.width >= 24, selection.height >= 12 {
                        translated = true; hasTried = true; focused = true
                    }
                    selection = nil
                })
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: translated)
            Divider().padding(.horizontal, 20)
            HStack(spacing: 12) {
                Text(hasTried ? L("按空格对照，再按一次切回。") : L("在上面的文字上拖动框选，试试看。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(hasTried ? L("原文 / 译文") : L("试一下翻译")) {
                    translated.toggle(); hasTried = true; focused = true
                }.controlSize(.small)
            }.padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(SettingsAppearance.canvas, in: RoundedRectangle(cornerRadius: OnboardingLayout.radius))
        .overlay(RoundedRectangle(cornerRadius: OnboardingLayout.radius).strokeBorder(Color.primary.opacity(0.08)))
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space, phases: .down) { _ in
            translated.toggle(); hasTried = true
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("原位翻译互动示例"))
    }
}
