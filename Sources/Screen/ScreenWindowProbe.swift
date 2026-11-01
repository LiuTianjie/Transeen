import AppKit
import CoreGraphics

enum ScreenWindowProbe {
    /// Resolve the real target even when capture was started from our menu-bar popover.
    static func application(at point: CGPoint) -> NSRunningApplication? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let top = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? 0
        let quartzPoint = CGPoint(x: point.x, y: top - point.y)
        for item in info {
            guard let pid = item[kCGWindowOwnerPID as String] as? pid_t, pid != ProcessInfo.processInfo.processIdentifier,
                  (item[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let dictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), bounds.contains(quartzPoint) else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    static func hoverBounds(at point: CGPoint, excludingPID pid: pid_t) -> CGRect? {
        let candidates = onscreenCandidates(excludingPID: pid)
        if let bounds = ScreenTranslate.topmostBounds(at: point, candidates: candidates) {
            return bounds
        }
        return NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
    }

    /// The application whose window is in front at `point`: its name as the window list gives it.
    static func owner(at point: CGPoint, excludingPID pid: pid_t) -> String? {
        let owner = onscreenCandidates(excludingPID: pid).first { $0.bounds.contains(point) }?.owner
        return owner?.isEmpty == false ? owner : nil
    }

    static func onscreenCandidates(excludingPID pid: pid_t) -> [ScreenTranslate.HoverCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let mainHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let skipped = Set(["Saylane", "Window Server", "Dock", "Control Center", "Notification Centre", "通知中心", "SystemUIServer"])
        var result: [ScreenTranslate.HoverCandidate] = []
        for item in info {
            let ownerPID = item[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if ownerPID == pid { continue }
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }
            let alpha = (item[kCGWindowAlpha as String] as? CGFloat) ?? 1
            if alpha < 0.05 { continue }
            let sharing = item[kCGWindowSharingState as String] as? Int ?? 1
            if sharing == 0 { continue }
            let owner = item[kCGWindowOwnerName as String] as? String ?? ""
            if skipped.contains(owner) { continue }
            guard let boundsDict = item[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let cg = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            if cg.width < 48 || cg.height < 48 { continue }
            let bounds = ScreenTranslate.appKitRect(fromCGWindowBounds: cg, mainDisplayHeight: mainHeight)
            result.append(ScreenTranslate.HoverCandidate(bounds: bounds, owner: owner))
        }
        return result
    }
}
