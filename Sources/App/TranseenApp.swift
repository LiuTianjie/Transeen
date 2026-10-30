import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TranseenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(L("打开图片…")) { delegate.openImage() }.configuredShortcut(.openImage, in: delegate.settings.shortcuts)
                }
                CommandGroup(replacing: .appTermination) {
                    Button(L("退出 Transeen")) { NSApp.terminate(nil) }.configuredShortcut(.quit, in: delegate.settings.shortcuts)
                }
                CommandGroup(replacing: .appSettings) {
                    Button(L("设置…")) { delegate.showSettings() }.configuredShortcut(.settings, in: delegate.settings.shortcuts)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let settings = AppSettings()
    let capture = CaptureController()
    let license = LicenseManager.live()
    private let updates = UpdateChecker()
    private var licenseWindow: NSWindow?
    private var licenseObservation: AnyCancellable?
    private let shortcuts = GlobalShortcuts()
    private let permission = ScreenPermission()
    private var permissionWindow: NSWindow?
    private var status: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var homeWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var launcherPopover: NSPopover?
    private var launcherClickMonitor: Any?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Transeen")
        item.button?.target = self
        item.button?.action = #selector(toggleLauncher)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status = item
        buildStatusMenu()
        observeInterfaceLanguage()
        capture.authorize = { [weak self] in self?.authorize() ?? false }
        licenseObservation = license.$state.dropFirst().sink { [weak self] state in
            guard !state.isActivated else { return }
            self?.capture.close()
        }
        Task { await license.bootstrap() }
        capture.onReselect = { [weak self] mode in self?.start(mode) }
        capture.onError = { [weak self] message in self?.notice(message) }
        shortcuts.onPressed = { [weak self] action in
            guard let self, settings.shortcuts.recording == nil else { return }
            switch action {
            case .globalCompare: capture.action("toggle")
            case .captureTranslate: if !capture.repeatTranslateShortcut() { start(.translate) }
            case .captureScreenshot: start(.screenshot)
            default: break
            }
        }
        settings.shortcuts.validateGlobals = { [weak self] candidate in
            guard let self else { return nil }
            let failures = shortcuts.register(candidate)
            guard !failures.isEmpty else { return nil }
            if settings.shortcuts.recording == nil { _ = shortcuts.register(settings.shortcuts.bindings) }
            else { shortcuts.stop() }
            return L("快捷键注册失败，可能被系统或其他应用占用：") + failures.map(\.title).joined(separator: L("、")) + L("。原配置已保留。")
        }
        settings.shortcuts.onRecordingChanged = { [weak self] recording in
            guard let self else { return }
            if recording { shortcuts.stop() }
            else { _ = shortcuts.register(settings.shortcuts.bindings) }
        }
        settings.shortcuts.onChanged = { [weak self] in self?.refreshShortcutLabels() }
        let failures = shortcuts.register(settings.shortcuts.bindings)
        if !failures.isEmpty { settings.shortcuts.message = L("这些全局快捷键无法注册，请重新设置：") + failures.map(\.title).joined(separator: L("、")) }
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["TRANSEEN_PREVIEW"], let image = NSImage(contentsOfFile: path) {
            capture.preview(image)
            return
        }
        #endif
        // "introduced" marks installs from before the guide existed.
        let onboarded = UserDefaults.standard.bool(forKey: "onboarded") || UserDefaults.standard.bool(forKey: "introduced")
        if permission.pendingMode != nil { showPermissionGuide() }
        else if !onboarded { showOnboarding() }
        else { showHome() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHome() }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) { license.validateInBackgroundIfNeeded() }
    func applicationDidResignActive(_ notification: Notification) { launcherPopover?.performClose(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoringLauncherClicks()
        capture.close()
        LocalModelRuntime.shared.stop()
        shortcuts.stop()
        license.cancel()
    }

    func popoverDidShow(_ notification: Notification) {
        stopMonitoringLauncherClicks()
        // Mouse events in other apps are not delivered to this accessory app.
        launcherClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.launcherPopover?.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) { stopMonitoringLauncherClicks() }

    private func stopMonitoringLauncherClicks() {
        if let launcherClickMonitor { NSEvent.removeMonitor(launcherClickMonitor) }
        launcherClickMonitor = nil
    }
    private func menuItem(_ title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; return item
    }
    private func buildStatusMenu() {
        status?.button?.toolTip = L("Transeen · 截图与翻译")
        let menu = NSMenu()
        menu.addItem(menuItem("Transeen", action: nil))
        menu.addItem(.separator())
        menu.addItem(menuItem(settings.shortcuts.help(L("截图翻译"), .captureTranslate), action: #selector(translateCapture)))
        menu.addItem(menuItem(settings.shortcuts.help(L("截图标注"), .captureScreenshot), action: #selector(screenshot)))
        menu.addItem(menuItem(L("关闭当前截图"), action: #selector(closeCapture)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("新手引导…"), action: #selector(showOnboarding)))
        menu.addItem(menuItem(L("屏幕权限…"), action: #selector(showPermissionGuide)))
        menu.addItem(menuItem(L("设置…"), action: #selector(showSettings)))
        menu.addItem(menuItem(L("激活与账号…"), action: #selector(showLicense)))
        menu.addItem(menuItem(L("检查更新…"), action: #selector(checkForUpdates)))
        menu.addItem(menuItem(L("退出 Transeen"), action: #selector(quit)))
        statusMenu = menu
    }
    private func observeInterfaceLanguage() {
        withObservationTracking { _ = InterfaceLanguage.shared.language } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.buildStatusMenu()
                self.settings.shortcuts.message = ""
                self.onboardingWindow?.title = L("开始使用 Transeen")
                self.settingsWindow?.title = L("设置")
                self.licenseWindow?.title = L("Transeen · 激活与账号")
                self.capture.refreshLanguage()
                self.observeInterfaceLanguage()
            }
        }
    }
    private func refreshShortcutLabels() {
        for (index, action, title) in [(2, ShortcutAction.captureTranslate, L("截图翻译")), (3, .captureScreenshot, L("截图标注"))] {
            statusMenu?.item(at: index)?.title = settings.shortcuts.help(title, action)
        }
    }
    private func start(_ mode: CaptureMode) {
        guard authorize() else { return }
        permission.refresh()
        guard permission.granted else {
            permission.pendingMode = mode
            showPermissionGuide()
            return
        }
        permission.pendingMode = nil
        permissionWindow?.orderOut(nil)
        permissionWindow?.contentView = nil
        permissionWindow = nil
        let launcher = launcherPopover?.contentViewController?.view.window
        launcherPopover?.performClose(nil)
        capture.begin(mode: mode, settings: settings, leaving: launcher.map { [$0] } ?? [])
    }
    @objc private func showPermissionGuide() {
        if permissionWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 445), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Transeen"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let view = PermissionGuide(permission: permission, continueCapture: { [weak self] in
                guard let self else { return }; start(permission.pendingMode ?? .translate)
            }, later: { [weak self] in
                self?.permission.pendingMode = nil
                self?.permissionWindow?.orderOut(nil)
                self?.permissionWindow?.contentView = nil
                self?.permissionWindow = nil
                self?.showHome()
            })
            let host = NSHostingView(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            window.contentView = host
            permissionWindow = window
            window.center()
        }
        launcherPopover?.performClose(nil)
        homeWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            UserDefaults.standard.set(true, forKey: "onboarded")
            settings.shortcuts.recording = nil
            window.contentView = nil
            onboardingWindow = nil
            return
        }
        guard window === permissionWindow else { return }
        window.contentView = nil
        permissionWindow = nil
    }
    @objc private func showOnboarding() {
        launcherPopover?.performClose(nil)
        homeWindow?.orderOut(nil)
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L("开始使用 Transeen")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            let host = NSHostingView(rootView: OnboardingView(settings: settings, permission: permission, license: license,
                showLicense: { [weak self] in self?.showLicense() },
                finish: { [weak self] startCapture in
                    guard let self else { return }
                    onboardingWindow?.close()
                    if startCapture { start(.translate) } else { showHome() }
                }))
            window.contentView = host
            onboardingWindow = window
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func translateCapture() { start(.translate) }
    @objc private func screenshot() { start(.screenshot) }
    @objc private func closeCapture() { capture.close() }
    @objc private func quit() { NSApp.terminate(nil) }
    private func launcher(compact: Bool = false) -> LauncherView {
        LauncherView(settings: settings, permission: permission,
            start: { [weak self] in self?.start($0) },
            showSettings: { [weak self] in self?.showSettings() },
            showPermission: { [weak self] in self?.showPermissionGuide() },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            openImage: { [weak self] in self?.openImage() },
            closeCapture: { [weak self] in self?.capture.close() },
            quit: { NSApp.terminate(nil) }, showLicense: { [weak self] in self?.showLicense() }, checkForUpdates: { [weak self] in self?.checkForUpdates() }, license: license, compact: compact)
    }
    @objc private func toggleLauncher() {
        guard let button = status?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            launcherPopover?.performClose(nil)
            statusMenu?.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.minY), in: button)
            return
        }
        if let launcherPopover, launcherPopover.isShown { launcherPopover.performClose(nil); return }
        permission.refresh()
        let popover = launcherPopover ?? NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: launcher(compact: true).onExitCommand { [weak self] in
            self?.launcherPopover?.performClose(nil)
        })
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        launcherPopover = popover
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKey()
    }
    @objc private func showHome() {
        launcherPopover?.performClose(nil)
        settingsWindow?.orderOut(nil)
        permissionWindow?.orderOut(nil)
        if homeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Transeen"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            let host = ClearHostingView(rootView: launcher())
            host.sizingOptions = [.preferredContentSize]
            window.contentView = host
            window.setContentSize(host.fittingSize)
            homeWindow = window
            window.center()
        }
        permission.refresh()
        NSApp.activate(ignoringOtherApps: true)
        homeWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openImage() {
        guard authorize() else { return }
        launcherPopover?.performClose(nil)
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.prompt = L("打开")
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self, response == .OK, let url = picker.url,
                  let image = NSImage(contentsOf: url) else { return }
            self.homeWindow?.orderOut(nil)
            self.settingsWindow?.orderOut(nil)
            self.capture.openImage(image, settings: self.settings)
        }
    }
    @objc func showSettings() {
        launcherPopover?.performClose(nil)
        homeWindow?.orderOut(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 580), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L("设置"); window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, permission: permission, showHome: { [weak self] in self?.showHome() }, showPermission: { [weak self] in self?.showPermissionGuide() }, capture: { [weak self] in self?.start($0) }))
            settingsWindow = window; window.center()
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func authorize() -> Bool {
        license.validateInBackgroundIfNeeded()
        guard license.state.isActivated else { showLicense(); return false }
        return true
    }
    @objc private func checkForUpdates() { launcherPopover?.performClose(nil); updates.check() }
    @objc private func showLicense() {
        launcherPopover?.performClose(nil)
        if licenseWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L("Transeen · 激活与账号")
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: LicenseView(manager: license, done: { [weak self] in
                guard let self else { return }
                licenseWindow?.orderOut(nil)
                // Activation opened from the guide returns to its next step.
                if let onboardingWindow { onboardingWindow.makeKeyAndOrderFront(nil) } else { showHome() }
            }))
            host.sizingOptions = [.preferredContentSize]
            window.contentView = host
            window.setContentSize(host.fittingSize)
            licenseWindow = window; window.center()
        }
        Task { await license.bootstrap() }
        NSApp.activate(ignoringOtherApps: true); licenseWindow?.makeKeyAndOrderFront(nil)
    }
    private func notice(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Transeen"; alert.informativeText = text; alert.addButton(withTitle: L("知道了"))
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}

private enum SettingsPane: Int, CaseIterable, Identifiable {
    case general, translation, shortcuts
    var id: Int { rawValue }
    var title: String {
        switch self { case .general: L("通用"); case .translation: L("翻译"); case .shortcuts: L("快捷键") }
    }
    var subtitle: String {
        switch self {
        case .general: L("截图行为与屏幕权限")
        case .translation: L("语言、翻译服务与模型")
        case .shortcuts: L("自定义每个操作的按键")
        }
    }
    var icon: String {
        switch self { case .general: "gearshape.fill"; case .translation: "globe"; case .shortcuts: "command" }
    }
    var iconColors: [Color] {
        switch self { case .general: TilePalette.gray; case .translation: TilePalette.blue; case .shortcuts: TilePalette.graphite }
    }
}

private struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var permission: ScreenPermission
    var showHome: () -> Void
    var showPermission: () -> Void
    var capture: (CaptureMode) -> Void
    @State private var pane = SettingsPane.general
    @State private var packs = LanguagePacks()
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    IconTile(symbol: pane.icon, colors: pane.iconColors, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pane.title).font(.system(size: 20, weight: .bold))
                        Text(pane.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 4)
                content.formStyle(.grouped).scrollContentBackground(.hidden)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 580, maxHeight: .infinity)
        .ignoresSafeArea()
        .languagePacks(packs, for: settings)
        .onChange(of: pane) { settings.shortcuts.recording = nil }
        .onDisappear { settings.shortcuts.recording = nil }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Transeen").font(.system(size: 13, weight: .semibold))
                    Text(version).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 6).padding(.top, 48).padding(.bottom, 18)
            ForEach(SettingsPane.allCases) { item in
                let selected = item == pane
                Button { pane = item } label: {
                    HStack(spacing: 9) {
                        IconTile(symbol: item.icon, colors: item.iconColors)
                        Text(item.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).frame(height: 30)
                    .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
            Button(action: showPermission) {
                HStack(spacing: 7) {
                    Circle().fill(permission.granted ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(permission.granted ? L("屏幕权限已开启") : L("屏幕权限尚未开启")).lineLimit(1)
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 6)
            }.buttonStyle(.plain).help(L("查看权限"))
            Button(action: showHome) {
                Label(L("返回"), systemImage: "chevron.left").font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }.controlSize(.large)
        }
        .padding(12)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general:
            Form {
                Section(L("捕获")) {
                    ShortcutRow(shortcuts: settings.shortcuts, action: .captureTranslate)
                    ShortcutRow(shortcuts: settings.shortcuts, action: .captureScreenshot)
                    if !settings.shortcuts.message.isEmpty { Text(settings.shortcuts.message).font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(L("复制后关闭截图"), isOn: $settings.copyCloses)
                        Text(L("钉住的图片会继续保留。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L("屏幕权限")) {
                    HStack {
                        Label {
                            Text(permission.granted ? L("屏幕权限已开启") : L("屏幕权限尚未开启"))
                        } icon: {
                            Image(systemName: permission.granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(permission.granted ? Color.green : Color.orange)
                        }
                        Spacer()
                        Button(L("查看权限"), action: showPermission)
                    }
                }
            }
        case .translation:
            Form { Section { TranslationServiceFields(settings: settings, packs: packs) } }
        case .shortcuts:
            ShortcutSettingsView(shortcuts: settings.shortcuts)
        }
    }
}
