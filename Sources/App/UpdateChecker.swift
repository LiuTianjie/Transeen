import AppKit
import Foundation

struct ReleaseVersion: Comparable, Equatable {
    let components: [Int]
    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.allSatisfy({ Int($0) != nil }) else { return nil }
        components = pieces.map { Int($0)! } + Array(repeating: 0, count: 3 - pieces.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

@MainActor
final class UpdateChecker {
    private var task: Task<Void, Never>?
    static let releasesURL = URL(string: "https://github.com/LiuTianjie/Transeen/releases/latest")!
    struct Release: Decodable { let tag_name: String; let body: String?; let html_url: String; let draft: Bool; let prerelease: Bool }

    func check() {
        guard task == nil else { return }
        task = Task { @MainActor in
            defer { task = nil }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/LiuTianjie/Transeen/releases/latest")!)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Transeen", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                guard !release.draft, !release.prerelease, let latest = ReleaseVersion(release.tag_name), let installed = ReleaseVersion(current),
                      let url = URL(string: release.html_url), url.scheme == "https", url.host == "github.com",
                      url.path.hasPrefix("/LiuTianjie/Transeen/releases/") else { throw UpdateError.unavailable }
                let alert = NSAlert()
                if latest > installed {
                    alert.messageText = L("发现 Transeen %@", release.tag_name)
                    alert.informativeText = L("当前版本：%@", current) + "\n\n" + String((release.body ?? L("新版本已发布。")).prefix(1200))
                    alert.addButton(withTitle: L("查看并下载更新"))
                    alert.addButton(withTitle: L("稍后"))
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                } else {
                    alert.messageText = L("Transeen 已是最新版本")
                    alert.informativeText = L("当前版本：%@", current)
                    alert.addButton(withTitle: L("好"))
                    NSApp.activate(ignoringOtherApps: true); alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = L("暂时无法检查更新")
                alert.informativeText = L("请稍后重试，或打开 GitHub 查看最新版本。")
                alert.addButton(withTitle: L("打开下载页面")); alert.addButton(withTitle: L("关闭"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesURL) }
            }
        }
    }
    private enum UpdateError: Error { case unavailable }
}
