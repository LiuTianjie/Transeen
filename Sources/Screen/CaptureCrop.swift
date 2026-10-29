import CoreGraphics

/// Sides of a selection being dragged; corners move two.
struct ResizeEdges: OptionSet, Sendable {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1)
    static let right = ResizeEdges(rawValue: 2)
    static let bottom = ResizeEdges(rawValue: 4)
    static let top = ResizeEdges(rawValue: 8)
}

/// Crop the frozen display using AppKit points. CGImage crop coordinates start at the top-left.
enum CaptureCrop {
    static func crop(_ image: CGImage, rect: CGRect, screenFrame: CGRect) -> CGImage? {
        let clipped = rect.intersection(screenFrame)
        guard !clipped.isNull, !clipped.isEmpty, screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let sx = CGFloat(image.width) / screenFrame.width
        let sy = CGFloat(image.height) / screenFrame.height
        let pixels = CGRect(x: (clipped.minX - screenFrame.minX) * sx,
                            y: (screenFrame.maxY - clipped.maxY) * sy,
                            width: clipped.width * sx, height: clipped.height * sy).integral
        return image.cropping(to: pixels)
    }

    /// `rect` with the dragged `edges` moved by `delta`, kept inside `bounds` and no
    /// smaller than `minimum`. The opposite edges never move.
    static func resized(_ rect: CGRect, edges: ResizeEdges, by delta: CGPoint, within bounds: CGRect, minimum: CGFloat) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if edges.contains(.left) { minX = min(max(bounds.minX, minX + delta.x), maxX - minimum) }
        if edges.contains(.right) { maxX = max(min(bounds.maxX, maxX + delta.x), minX + minimum) }
        if edges.contains(.bottom) { minY = min(max(bounds.minY, minY + delta.y), maxY - minimum) }
        if edges.contains(.top) { maxY = max(min(bounds.maxY, maxY + delta.y), minY + minimum) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
