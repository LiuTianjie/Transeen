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
            Picker("原文", selection: Binding(get: { settings.detectsSource ? "auto" : settings.source.rawValue }, set: { value in
                settings.detectsSource = value == "auto"
                if let language = AppLanguage(rawValue: value) { settings.source = language }
            })) {
                Text("自动识别").tag("auto")
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("译文", selection: $settings.target) { ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) } }
        }
        Picker("翻译服务", selection: $settings.useModel) {
            Text("Apple 本机翻译").tag(false)
            Text("大模型 / 本地模型服务").tag(true)
        }
        if !settings.useModel {
            ForEach(packs.sources) { language in
                HStack {
                    Text("\(language.displayName) → \(packs.target.displayName)")
                    Spacer()
                    status(language)
                }
            }
            if let message = packs.message { Text(message).font(.caption).foregroundStyle(.orange) }
            Text(settings.detectsSource ? "原文为自动识别：下载你常看的语言即可。语言包由系统下载，之后离线翻译。" : "语言包由系统下载，之后离线翻译。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            TextField("接口地址", text: $settings.endpoint)
            TextField("模型名称", text: $settings.model)
            SecureField("API Key（本机服务可留空）", text: $apiKey)
            HStack {
                Button("保存密钥") { saveKey() }
                Button(testing ? "正在连接…" : "测试连接") { test() }.disabled(testing)
                Text(keyStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("兼容 chat/completions；只发送识别后的文本。远程接口使用 HTTPS，本机服务可用 HTTP。").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(_ language: AppLanguage) -> some View {
        switch packs.statuses[language] ?? .checking {
        case .checking: ProgressView().controlSize(.small)
        case .installed:
            Label("已下载", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        case .missing:
            Button("下载") { packs.download(language) }.disabled(packs.isDownloading)
                .accessibilityLabel("下载 \(language.displayName) 到 \(packs.target.displayName) 语言包")
        case .downloading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("下载中…").font(.callout).foregroundStyle(.secondary) }
        case .unsupported:
            Text("系统暂不支持").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        do {
            let config = try ModelConfiguration(endpoint: settings.endpoint, model: settings.model)
            try ModelKeychain.save(apiKey, endpoint: config.endpoint)
            keyStatus = apiKey.isEmpty ? "已清除该接口密钥" : "已保存到钥匙串"
            apiKey = ""
        } catch { keyStatus = error.localizedDescription }
    }

    /// The same request path a capture takes, with the saved key.
    private func test() {
        guard apiKey.isEmpty else { keyStatus = "请先保存密钥，再测试连接。"; return }
        testing = true
        keyStatus = ""
        Task { @MainActor in
            defer { testing = false }
            do {
                let config = try ModelConfiguration(endpoint: settings.endpoint, model: settings.model)
                let key = try ModelKeychain.read(endpoint: config.endpoint)
                _ = try await ModelHTTP.chat(configuration: config, apiKey: key, system: "Reply with the single word OK.", user: "OK", timeout: 20)
                keyStatus = "连接成功，可以翻译"
            } catch { keyStatus = error.localizedDescription }
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
