import CoreGraphics
import Foundation

/// A colour in 0...255 per channel, sRGB.
struct RGB: Sendable, Equatable {
    var r: Float, g: Float, b: Float

    static func - (a: RGB, b: RGB) -> RGB { RGB(r: a.r - b.r, g: a.g - b.g, b: a.b - b.b) }
    static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
    static func * (a: RGB, k: Float) -> RGB { RGB(r: a.r * k, g: a.g * k, b: a.b * k) }
    var length: Float { (r * r + g * g + b * b).squareRoot() }
    func distance(to other: RGB) -> Float { (self - other).length }
    var luma: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var clamped: RGB { RGB(r: min(255, max(0, r)), g: min(255, max(0, g)), b: min(255, max(0, b))) }
}

/// Integer pixel rectangle, top-left origin, `maxX`/`maxY` exclusive.
struct PixelRect: Sendable, Equatable {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    /// The pixels a rectangle touches, grown by `pad`, kept inside `bounds`.
    init(_ rect: CGRect, pad: CGFloat = 0, in bounds: PixelRect) {
        // An inset narrower than its padding produces CGRect.null. Clamp in
        // floating point before converting: null/overflow must yield no pixels.
        guard !rect.isNull, !rect.isEmpty, !bounds.isEmpty, pad.isFinite,
              rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else {
            self.init(minX: bounds.minX, minY: bounds.minY, maxX: bounds.minX, maxY: bounds.minY)
            return
        }
        let left = min(CGFloat(bounds.maxX), max(CGFloat(bounds.minX), floor(rect.minX - pad)))
        let top = min(CGFloat(bounds.maxY), max(CGFloat(bounds.minY), floor(rect.minY - pad)))
        let right = min(CGFloat(bounds.maxX), max(left, ceil(rect.maxX + pad)))
        let bottom = min(CGFloat(bounds.maxY), max(top, ceil(rect.maxY + pad)))
        self.init(minX: Int(left), minY: Int(top), maxX: Int(right), maxY: Int(bottom))
    }

    var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

/// The screenshot as bytes: RGBA, 8 bits, sRGB, row 0 at the top.
struct PixelImage: @unchecked Sendable {
    let width: Int
    let height: Int
    var data: [UInt8]

    var bounds: PixelRect { PixelRect(minX: 0, minY: 0, maxX: width, maxY: height) }

    init(width: Int, height: Int, fill: RGB = RGB(r: 255, g: 255, b: 255)) {
        self.width = width
        self.height = height
        data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4] = UInt8(fill.r); data[i * 4 + 1] = UInt8(fill.g); data[i * 4 + 2] = UInt8(fill.b)
        }
    }

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { return nil }
    }

    @inline(__always) subscript(x: Int, y: Int) -> RGB {
        get {
            let i = (y * width + x) * 4
            return RGB(r: Float(data[i]), g: Float(data[i + 1]), b: Float(data[i + 2]))
        }
        set {
            let i = (y * width + x) * 4
            let c = newValue.clamped
            data[i] = UInt8(c.r.rounded()); data[i + 1] = UInt8(c.g.rounded()); data[i + 2] = UInt8(c.b.rounded())
        }
    }

    mutating func fill(_ rect: CGRect, with colour: RGB) {
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 { for x in x0..<x1 { self[x, y] = colour } }
    }

    /// `rect` of `source` placed with its top-left corner at `origin`, whole pixels.
    mutating func copy(_ rect: CGRect, from source: PixelImage, to origin: CGPoint) {
        let dx = Int(origin.x.rounded()) - Int(rect.minX), dy = Int(origin.y.rounded()) - Int(rect.minY)
        let x0 = max(0, Int(rect.minX)), x1 = min(source.width, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY)), y1 = min(source.height, Int(rect.maxY.rounded(.up)))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 where (0..<height).contains(y + dy) {
            for x in x0..<x1 where (0..<width).contains(x + dx) { self[x + dx, y + dy] = source[x, y] }
        }
    }

    func cgImage() -> CGImage? {
        var copy = data
        return copy.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage()
        }
    }
}

func median<T: Comparable>(_ values: [T]) -> T? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
}

func percentile(_ values: [Float], _ q: Float) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * q)))]
}
