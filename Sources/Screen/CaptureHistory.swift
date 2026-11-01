import AppKit
import SwiftUI
import ImageIO

/// Only flattened, user-visible results are retained; no hidden original/translation layers.
@MainActor @Observable
final class CaptureHistory {
    static let shared = CaptureHistory()
    struct Entry: Identifiable, Codable, Equatable {
        var id: UUID
        var date: Date
        var width: Int
        var height: Int
    }
    private(set) var entries: [Entry] = []
    private(set) var error: String?
    private let directory: URL
    private let defaults: UserDefaults
    private var revision = 0
    private var pending: [UUID: UUID] = [:]
    private var cleanupTask: Task<Void, Never>?
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "captureHistoryEnabled")
            if !isEnabled { clear() }
        }
    }
    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: "captureHistoryDays"); prune() }
    }
    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transeen/CaptureHistory", isDirectory: true)
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "captureHistoryEnabled") == nil || defaults.bool(forKey: "captureHistoryEnabled")
        let days = defaults.integer(forKey: "captureHistoryDays")
        retentionDays = [1, 7, 30].contains(days) ? days : 7
        let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
        entries = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  FileManager.default.fileExists(atPath: self.directory.appendingPathComponent(entry.id.uuidString + ".png").path) else { return nil }
            return entry
        }.sorted { $0.date > $1.date }
        if isEnabled { prune() } else { clear() }
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
                guard let self else { return }
                self.prune()
            }
        }
    }
    isolated deinit { cleanupTask?.cancel() }
    func imageURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".png") }
    func image(_ id: UUID) -> NSImage? { NSImage(contentsOf: imageURL(id)) }
    func thumbnail(_ id: UUID) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL(id) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 360, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
    /// Awaitable so shutdown and tests can drain writes without taking another capture.
    func record(_ image: CGImage, id: UUID, date: Date = Date()) async {
        guard isEnabled else { return }
        let version = revision
        let token = UUID()
        pending[id] = token
        let data = await Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data?.none }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return Data?.none }
            return data as Data
        }.value
        guard isEnabled, revision == version, pending[id] == token else { return }
        pending[id] = nil
        guard let data, data.count <= 200 * 1024 * 1024 else { error = L("截图过大，未加入最近截图"); return }
        let entry = Entry(id: id, date: date, width: image.width, height: image.height)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: imageURL(id), options: .atomic)
            try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
            entries.removeAll { $0.id == id }
            entries.insert(entry, at: 0)
            error = nil
            prune()
        } catch { self.error = L("最近截图保存失败：%@", error.localizedDescription) }
    }
    func remove(_ id: UUID) {
        pending[id] = nil
        do {
            for ext in ["png", "json"] {
                let url = directory.appendingPathComponent(id.uuidString + "." + ext)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            entries.removeAll { $0.id == id }
        } catch { self.error = error.localizedDescription }
    }
    func clear() {
        revision += 1; pending = [:]
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            entries = []; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        var bytes = 0
        for (index, entry) in entries.sorted(by: { $0.date > $1.date }).enumerated() {
            let size = (try? imageURL(entry.id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += size
            if entry.date < cutoff || index >= 50 || bytes > 200 * 1024 * 1024 { remove(entry.id) }
        }
    }
}

struct CaptureHistoryView: View {
    @Bindable var history: CaptureHistory
    var restore: (CaptureHistory.Entry) -> Void
    @State private var confirmsClear = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(L("保留最近截图"), isOn: $history.isEnabled)
                Spacer()
                Picker(L("保留时间"), selection: $history.retentionDays) {
                    Text(L("1 天")).tag(1)
                    Text(L("7 天")).tag(7)
                    Text(L("30 天")).tag(30)
                }.frame(width: 155).disabled(!history.isEnabled)
                Button(L("清空…")) { confirmsClear = true }.disabled(history.entries.isEmpty)
            }.padding(16)
            Text(L("仅保存在本机，最多 50 张 / 200 MB；关闭保留会清空记录。恢复的是合并标注后的图片。"))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if let error = history.error { Text(error).foregroundStyle(.red).font(.caption).padding(10) }
            if history.entries.isEmpty {
                ContentUnavailableView(L("暂无最近截图"), systemImage: "clock.arrow.circlepath", description: Text(L("关闭、复制或保存截图后，可以在这里恢复。")))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], spacing: 16) {
                        ForEach(history.entries) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { restore(entry) } label: {
                                    Group {
                                        if let image = history.thumbnail(entry.id) { Image(nsImage: image).resizable().scaledToFit() }
                                        else { Image(systemName: "photo") }
                                    }.frame(maxWidth: .infinity).frame(height: 125)
                                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).help(L("恢复截图"))
                                Text(entry.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text("\(entry.width) × \(entry.height)").font(.caption.monospacedDigit())
                                    Spacer()
                                    Button { restore(entry) } label: { Image(systemName: "arrow.uturn.backward") }.help(L("恢复截图"))
                                    Button { history.remove(entry.id) } label: { Image(systemName: "trash") }.help(L("删除截图"))
                                }.buttonStyle(.borderless)
                            }.padding(10).background(SettingsAppearance.panel, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(16)
                }
            }
        }.frame(minWidth: 650, minHeight: 440).settingsSurface()
            .onAppear { history.prune() }
            .alert(L("清空最近截图？"), isPresented: $confirmsClear) {
                Button(L("清空"), role: .destructive) { history.clear() }
                Button(L("取消"), role: .cancel) { }
            }
    }
}
