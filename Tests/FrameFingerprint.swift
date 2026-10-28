import CoreGraphics

/// Downsample the whole area, not a few pixels: narrow text changes still affect the digest.
struct FrameFingerprint: Equatable {
    let bytes: [UInt8]
    init?(_ image: CGImage) {
        let width = min(image.width, 480)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        bytes = pixels
    }
}
