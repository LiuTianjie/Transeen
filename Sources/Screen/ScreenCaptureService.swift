import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case notAuthorized
    case noDisplay
    case failed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return L("所见即译需要屏幕录制权限。")
        case .noDisplay: return L("找不到这块屏幕。")
        case .failed: return L("截取屏幕失败，请重试。")
        }
    }
}

enum ScreenCaptureService {
    /// Reuse the display/filter for a scrolling session instead of discovering windows for every frame.
    @MainActor final class SnapshotSource {
        private let filter: SCContentFilter
        private let configuration: SCStreamConfiguration
        init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
            self.filter = filter; self.configuration = configuration
        }
        func capture() async throws -> CGImage {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    @MainActor static func scrollingSource(rect: CGRect, display screen: Display) async throws -> SnapshotSource {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw ScreenCaptureError.noDisplay }
        // Window IDs also work when ScreenCaptureKit omits this process from its application list.
        // The session creates its outline and controls before preparing this source.
        let ours = Set(NSApp.windows.map { CGWindowID($0.windowNumber) })
        let excluded = content.windows.filter {
            ours.contains($0.windowID) || $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = ScreenTranslate.captureSourceRect(appKitRect: rect, screenFrame: screen.frame)
        configuration.width = max(1, Int((rect.width * screen.backingScaleFactor).rounded()))
        configuration.height = max(1, Int((rect.height * screen.backingScaleFactor).rounded()))
        configuration.showsCursor = false
        return SnapshotSource(filter: filter, configuration: configuration)
    }

    /// The few facts about an `NSScreen` the capture needs, so the capture can run off the main actor.
    struct Display: Sendable {
        var frame: CGRect
        var displayID: CGDirectDisplayID
        var backingScaleFactor: CGFloat

        @MainActor init(_ screen: NSScreen) {
            frame = screen.frame
            displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            backingScaleFactor = screen.backingScaleFactor
        }
    }

    @MainActor static func capture(rectInScreen: CGRect, screen: NSScreen) async throws -> NSImage {
        try await capture(rectInScreen: rectInScreen, display: Display(screen))
    }

    static func capture(rectInScreen: CGRect, display screen: Display) async throws -> NSImage {
        let image = try await captureImage(rectInScreen: rectInScreen, display: screen)
        let source = ScreenTranslate.captureSourceRect(appKitRect: rectInScreen, screenFrame: screen.frame)
        return NSImage(cgImage: image, size: source.size)
    }

    /// The pixels of `rectInScreen` at the display's backing scale: without our own windows,
    /// or with them except `excluding` when that is given.
    static func captureImage(rectInScreen: CGRect, display screen: Display, excluding windows: Set<CGWindowID>? = nil) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.notAuthorized }
        let source = ScreenTranslate.captureSourceRect(appKitRect: rectInScreen, screenFrame: screen.frame)
        guard source.width >= ScreenTranslate.minimumSelection, source.height >= ScreenTranslate.minimumSelection else {
            throw ScreenCaptureError.failed
        }
        let displayID = screen.displayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { window in
            guard window.owningApplication?.processID == pid else { return false }
            // A selection overlay still on its way out is never part of the picture.
            return windows.map { $0.contains(window.windowID) || window.windowLayer >= Int(CGWindowLevelForKey(.screenSaverWindow)) } ?? true
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(1, Int((source.width * screen.backingScaleFactor).rounded()))
        config.height = max(1, Int((source.height * screen.backingScaleFactor).rounded()))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
