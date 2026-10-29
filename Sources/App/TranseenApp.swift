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
                    Button("打开图片…") { delegate.openImage() }.configuredShortcut(.openImage, in: delegate.settings.shortcuts)
                }
                CommandGroup(replacing: .appTermination) {
                    Button("退出 Transeen") { NSApp.terminate(nil) }.configuredShortcut(.quit, in: delegate.settings.shortcuts)
                }
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { delegate.showSettings() }.configuredShortcut(.settings, in: delegate.settings.shortcuts)
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
        item.button?.toolTip = "Transeen · 截图与翻译"
        let menu = NSMenu()
        menu.addItem(menuItem("Transeen", action: nil))
        menu.addItem(.separator())
        menu.addItem(menuItem(settings.shortcuts.help("截图翻译", .captureTranslate), action: #selector(translateCapture)))
        menu.addItem(menuItem(settings.shortcuts.help("截图标注", .captureScreenshot), action: #selector(screenshot)))
        menu.addItem(menuItem("关闭当前截图", action: #selector(closeCapture)))
        menu.addItem(.separator())
        menu.addItem(menuItem("新手引导…", action: #selector(showOnboarding)))
        menu.addItem(menuItem("屏幕权限…", action: #selector(showPermissionGuide)))
        menu.addItem(menuItem("设置…", action: #selector(showSettings)))
        menu.addItem(menuItem("激活与账号…", action: #selector(showLicense)))
        menu.addItem(menuItem("检查更新…", action: #selector(checkForUpdates)))
        menu.addItem(menuItem("退出 Transeen", action: #selector(quit)))
        statusMenu = menu
        item.button?.target = self
        item.button?.action = #selector(toggleLauncher)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status = item
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
            case .captureTranslate: start(.translate)
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
            return "快捷键注册失败，可能被系统或其他应用占用：" + failures.map(\.title).joined(separator: "、") + "。原配置已保留。"
        }
        settings.shortcuts.onRecordingChanged = { [weak self] recording in
            guard let self else { return }
            if recording { shortcuts.stop() }
            else { _ = shortcuts.register(settings.shortcuts.bindings) }
        }
        settings.shortcuts.onChanged = { [weak self] in self?.refreshShortcutLabels() }
        let failures = shortcuts.register(settings.shortcuts.bindings)
        if !failures.isEmpty { settings.shortcuts.message = "这些全局快捷键无法注册，请重新设置：" + failures.map(\.title).joined(separator: "、") }
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
    private func refreshShortcutLabels() {
        for (index, action, title) in [(2, ShortcutAction.captureTranslate, "截图翻译"), (3, .captureScreenshot, "截图标注")] {
            statusMenu?.item(at: index)?.title = settings.shortcuts.help(title, action)
        }
    }
    private func start(_ mode: CaptureMode) {
        guard authorize() else { return }
        launcherPopover?.performClose(nil)
        homeWindow?.orderOut(nil)
        onboardingWindow?.orderOut(nil)
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
        settingsWindow?.orderOut(nil)
        capture.begin(mode: mode, settings: settings)
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "开始使用 Transeen"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let host = NSHostingView(rootView: OnboardingView(settings: settings, permission: permission, license: license,
                showLicense: { [weak self] in self?.showLicense() },
                finish: { [weak self] startCapture in
                    guard let self else { return }
                    onboardingWindow?.close()
                    if startCapture { start(.translate) } else { showHome() }
                }))
            host.sizingOptions = [.preferredContentSize]
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
        picker.prompt = "打开"
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 570), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "设置"; window.isReleasedWhenClosed = false
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
            window.title = "Transeen · 激活与账号"
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
        let alert = NSAlert(); alert.messageText = "Transeen"; alert.informativeText = text; alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}

private struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var permission: ScreenPermission
    var showHome: () -> Void
    var showPermission: () -> Void
    var capture: (CaptureMode) -> Void
    @State private var tab = 0
    @State private var packs = LanguagePacks()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Button(action: showHome) { Image(systemName: "chevron.left").frame(width: 24, height: 24) }.buttonStyle(.glass).help("返回")
                Text("设置").font(.system(size: 21, weight: .semibold))
                Spacer()
                Text("Transeen " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(22)
            Picker("设置分类", selection: $tab) {
                Text("通用").tag(0)
                Text("快捷键").tag(1)
            }.pickerStyle(.segmented).padding(.horizontal, 22).padding(.bottom, 10)
            if tab == 1 {
                ShortcutSettingsView(shortcuts: settings.shortcuts)
            } else {
            Form {
                Section("捕获") {
                    ShortcutRow(shortcuts: settings.shortcuts, action: .captureTranslate)
                    ShortcutRow(shortcuts: settings.shortcuts, action: .captureScreenshot)
                    if !settings.shortcuts.message.isEmpty { Text(settings.shortcuts.message).font(.caption).foregroundStyle(.secondary) }
                    Toggle("复制后关闭截图", isOn: $settings.copyCloses)
                    Text("钉住的图片会继续保留。").font(.caption).foregroundStyle(.secondary)
                }
                Section("翻译") { TranslationServiceFields(settings: settings, packs: packs) }
                Section("屏幕权限") {
                    HStack {
                        Label(permission.granted ? "屏幕权限已开启" : "屏幕权限尚未开启", systemImage: permission.granted ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(permission.granted ? Color.green : Color.secondary)
                        Spacer()
                        Button("查看权限", action: showPermission)
                    }
                }
            }.formStyle(.grouped)
                .onDisappear { settings.shortcuts.recording = nil }
            }
        }.frame(width: 540, height: 570)
            .languagePacks(packs, for: settings)
    }
}
