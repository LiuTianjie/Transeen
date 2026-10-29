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
        if settings.service == .remote { return translationReady ? "已填写模型接口，可先测试连接" : "填写 chat/completions 接口地址和模型名称" }
        if settings.service == .local { return translationReady ? "\(settings.selectedLocalModel.name) 已下载，可离线翻译" : "下载一个本地模型（约 1.1 GB），之后完全离线翻译" }
        if packs.sources.isEmpty { return "这对语言不需要下载" }
        if packs.installedCount == 0 { return "先下载要翻译的语言，第一次截图就不用等" }
        return "已下载 \(packs.installedCount)/\(packs.sources.count) 个语言包，需要时再补充"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable().interpolation(.high).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("欢迎使用 Transeen").font(.system(size: 20, weight: .medium, design: .rounded)).tracking(-0.3)
                    Text("先把这几项准备好，用的时候就不用等。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 6)

            Form {
                Section {
                    SetupStep(number: 1, title: "激活 Transeen", detail: license.state.isActivated ? "截图、标注与翻译已解锁" : "需要 TR- 激活码，无需登录", done: license.state.isActivated) {
                        if license.state == .checking { ProgressView().controlSize(.small) }
                        else if !license.state.isActivated { Button("输入激活码…", action: showLicense) }
                    }
                }
                Section {
                    SetupStep(number: 2, title: "允许录制屏幕", detail: permission.granted ? "已开启" : permission.requested ? "已开启但仍未生效时，重新打开 Transeen" : "只读取屏幕图像，不采集音频", done: permission.granted) {
                        if !permission.granted {
                            HStack {
                                if permission.requested { Button("重新打开") { permission.relaunch() } }
                                Button("打开系统设置…") { permission.openSettings() }
                            }
                        }
                    }
                }
                Section {
                    SetupStep(number: 3, title: "准备翻译", detail: translationDetail, done: translationReady) { EmptyView() }
                    TranslationServiceFields(settings: settings, packs: packs)
                }
                Section {
                    SetupStep(number: 4, title: "确认快捷键", detail: "按下即框选；松开后拖动结果边缘可调整范围", done: settings.shortcuts.binding(.captureTranslate) != nil || settings.shortcuts.binding(.captureScreenshot) != nil) { EmptyView() }
                    ShortcutRow(shortcuts: settings.shortcuts, action: .captureTranslate)
                    ShortcutRow(shortcuts: settings.shortcuts, action: .captureScreenshot)
                    if !settings.shortcuts.message.isEmpty { Text(settings.shortcuts.message).font(.caption).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped)

            Divider()
            HStack {
                Button("稍后") { finish(false) }.keyboardShortcut(.cancelAction)
                Text("可随时从菜单栏打开「新手引导…」").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("开始截图翻译") { finish(true) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }.padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 540, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
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
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var trailing: Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.14))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
            }.frame(width: 22, height: 22)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("第 \(number) 步：\(title)，\(done ? "已完成" : detail)")
    }
}
