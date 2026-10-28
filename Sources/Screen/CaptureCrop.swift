import CoreGraphics

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
}
