import AppKit
import OSLog
import Sparkle

/// Updates Transeen in place with Sparkle: it reads the appcast once a day, verifies the
/// archive's EdDSA signature and the new app's code signature, and replaces the app after
/// the user agrees. Only Developer ID builds carry a feed (scripts/build.sh sets it); ad hoc
/// and development builds fall back to `UpdateChecker`, which links to the GitHub release.
@MainActor
final class AppUpdater {
    private static let logger = Logger(subsystem: "com.transeen.app", category: "AppUpdater")
    private var controller: SPUStandardUpdaterController?
    private let fallback = UpdateChecker()

    func start() {
        guard controller == nil, Self.isConfigured(Bundle.main.infoDictionary) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            Self.logger.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        controller.updater.sendsSystemProfile = false
        self.controller = controller
    }

    /// Sparkle's update window when it runs, otherwise the GitHub release check.
    func check() {
        guard let controller else { fallback.check(); return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    nonisolated static func isConfigured(_ info: [String: Any]?) -> Bool {
        guard let feed = info?["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https",
              let key = info?["SUPublicEDKey"] as? String, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return true
    }
}
