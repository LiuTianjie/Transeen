import AppKit
import SwiftUI
@preconcurrency import Translation

/// Languages and translation service, shared by Settings and the first-run guide.
/// Place inside a Form section; the hosting view applies `.languagePacks`.
struct TranslationServiceFields: View {
    @Bindable var settings: AppSettings
    var packs: LanguagePacks
    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var testing = false

    var body: some View {
        HStack {
            Picker(L("原文"), selection: Binding(get: { settings.detectsSource ? "auto" : settings.source.rawValue }, set: { value in
                settings.detectsSource = value == "auto"
                if let language = AppLanguage(rawValue: value) { settings.source = language }
            })) {
                Text(L("自动识别")).tag("auto")
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker(L("译文"), selection: $settings.target) { ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) } }
        }
        Picker(L("翻译服务"), selection: $settings.service) {
            Text(L("Apple 本机翻译")).tag(TranslationService.apple)
            Text(L("本地翻译模型")).tag(TranslationService.local)
            Text(L("大模型接口")).tag(TranslationService.remote)
        }
        switch settings.service {
        case .local:
            LocalModelFields(settings: settings)
        case .apple:
            ForEach(packs.sources) { language in
                HStack {
                    Text("\(language.displayName) → \(packs.target.displayName)")
                    Spacer()
                    status(language)
                }
            }
            if let message = packs.message { Text(message).font(.caption).foregroundStyle(.orange) }
            Text(settings.detectsSource ? L("原文为自动识别：下载你常看的语言即可。语言包由系统下载，之后离线翻译。") : L("语言包由系统下载，之后离线翻译。"))
                .font(.caption).foregroundStyle(.secondary)
        case .remote:
            TextField(L("接口地址"), text: $settings.endpoint)
            TextField(L("模型名称"), text: $settings.model)
            SecureField(L("API Key（本机服务可留空）"), text: $apiKey)
            HStack {
                Button(L("保存密钥")) { saveKey() }
                Button(testing ? L("正在连接…") : L("测试连接")) { test() }.disabled(testing)
                Text(keyStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(L("兼容 chat/completions；只发送识别后的文本。远程接口使用 HTTPS，本机服务可用 HTTP。")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(_ language: AppLanguage) -> some View {
        switch packs.statuses[language] ?? .checking {
        case .checking: ProgressView().controlSize(.small)
        case .installed:
            Label(L("已下载"), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        case .missing:
            Button(L("下载")) { packs.download(language) }.disabled(packs.isDownloading)
                .accessibilityLabel(L("下载 %@ 到 %@ 语言包", language.displayName, packs.target.displayName))
        case .downloading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("下载中…")).font(.callout).foregroundStyle(.secondary) }
        case .unsupported:
            Text(L("系统暂不支持")).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        do {
            let config = try ModelConfiguration(endpoint: settings.endpoint, model: settings.model)
            try ModelKeychain.save(apiKey, endpoint: config.endpoint)
            keyStatus = apiKey.isEmpty ? L("已清除该接口密钥") : L("已保存到钥匙串")
            apiKey = ""
        } catch { keyStatus = error.localizedDescription }
    }

    /// The same request path a capture takes, with the saved key.
    private func test() {
        guard apiKey.isEmpty else { keyStatus = L("请先保存密钥，再测试连接。"); return }
        testing = true
        keyStatus = ""
        Task { @MainActor in
            defer { testing = false }
            do {
                let config = try ModelConfiguration(endpoint: settings.endpoint, model: settings.model)
                let key = try ModelKeychain.read(endpoint: config.endpoint)
                _ = try await ModelHTTP.chat(configuration: config, apiKey: key, system: "Reply with the single word OK.", user: "OK", timeout: 20)
                keyStatus = L("连接成功，可以翻译")
            } catch { keyStatus = error.localizedDescription }
        }
    }
}

/// Downloadable models that run on this Mac. Choosing one that is not downloaded yet is
/// allowed; captures then say so until the download finishes.
struct LocalModelFields: View {
    @Bindable var settings: AppSettings
    var store = LocalModelStore.shared

    var body: some View {
        if !LocalModelRuntime.isSupported {
            Text(L("本地翻译模型需要 Apple 芯片的 Mac。")).font(.callout).foregroundStyle(.orange)
        }
        ForEach(LocalModelCatalog.all) { model in
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: settings.localModel == model.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(settings.localModel == model.id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name + (model.id == LocalModelCatalog.defaultID ? L("（推荐）") : ""))
                    Text("\(model.summary) · \(model.sizeText)").font(.caption).foregroundStyle(.secondary)
                    if case .failed(let message) = store.status(model) {
                        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                status(model)
            }
            .contentShape(Rectangle())
            .onTapGesture { settings.localModel = model.id }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(settings.localModel == model.id ? .isSelected : [])
        }
        Text(L("模型下载后完全在本机运行，截图文字不会离开这台 Mac。首次翻译需要几秒加载模型，空闲 5 分钟后自动释放内存。"))
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func status(_ model: LocalModel) -> some View {
        switch store.status(model) {
        case .installed:
            HStack(spacing: 8) {
                Label(L("已下载"), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                Menu {
                    Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([store.url(for: model)]) }
                    Button(L("删除模型"), role: .destructive) {
                        if settings.localModel == model.id { LocalModelRuntime.shared.stop() }
                        store.delete(model)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("%@ 更多操作", model.name))
            }
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 80)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(L("停止")) { store.cancel(model) }.controlSize(.small)
            }
        case .missing, .failed:
            Button(L("下载")) {
                settings.localModel = model.id
                store.download(model)
            }
            .disabled(!LocalModelRuntime.isSupported)
            .accessibilityLabel(L("下载 %@，%@", model.name, model.sizeText))
        }
    }
}

extension View {
    /// Hosts the download prompt for `packs` and keeps its statuses current.
    func languagePacks(_ packs: LanguagePacks, for settings: AppSettings) -> some View {
        let refresh = { await packs.refresh(source: settings.detectsSource ? nil : settings.source, target: settings.target) }
        return translationTask(packs.configuration) { session in await packs.handle(session) }
            .task(id: "\(settings.detectsSource) \(settings.source.rawValue) \(settings.target.rawValue)") { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refresh() }
            }
    }
}
