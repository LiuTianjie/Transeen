import CoreGraphics
import Foundation
import Vision

/// Incremental overlap stitching; see docs/scrolling-capture.md for product references.
/// Vision supplies translation registration; pixel checks reject ambiguous/animated overlaps.
actor ScrollStitcher {
    enum Outcome: Sendable, Equatable { case started, appended, unchanged, revisiting, noMatch, limit }
    struct Update: Sendable {
        let outcome: Outcome
        let height: Int
        let count: Int
        let preview: CGImage?
    }
    private var image: CGImage?
    private var previous: CGImage?
    private var position = 0
    private var furthest = 0
    private var count = 0
    private var fixedBottom = 0
    private let maxPixels: Int
    private let maxHeight: Int
    init(maxPixels: Int = 60_000_000, maxHeight: Int = 30_000) {
        self.maxPixels = maxPixels; self.maxHeight = maxHeight
    }

    func add(_ next: CGImage) -> Update {
        guard let previous, let image else {
            guard next.width * next.height <= maxPixels, next.height <= maxHeight else { return update(.limit) }
            self.previous = next; self.image = next; count = 1
            return update(.started)
        }
        guard previous.width == next.width, previous.height == next.height else { return update(.noMatch) }
        guard let a = GrayRows(previous), let b = GrayRows(next) else { return update(.noMatch) }
        if a.difference(b, shift: 0, trim: 0) < 0.5 { return update(.unchanged) }
        guard let shift = Self.displacement(previous, next, a: a, b: b) else { return update(.noMatch) }
        if shift == 0 { return update(.unchanged) }
        let newPosition = position + shift
        let added = max(0, newPosition - furthest)
        if added == 0 {
            self.previous = next; position = newPosition
            return update(.revisiting)
        }
        // Detect a fixed footer only once, as in established scrolling-capture pipelines.
        // It stays at the end and is replaced by the footer from each new frame.
        let footer = count == 1 ? a.fixedBottomRows(b) : fixedBottom
        guard added < next.height - footer, added > 0 else { return update(.noMatch) }
        let totalHeight = image.height + added
        guard totalHeight <= maxHeight, image.width * totalHeight <= maxPixels else { return update(.limit) }
        let retained = image.height - footer
        let tailHeight = added + footer
        guard let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: retained)),
              let tail = next.cropping(to: CGRect(x: 0, y: next.height - tailHeight, width: next.width, height: tailHeight)),
              let context = CGContext(data: nil, width: next.width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return update(.limit) }
        context.interpolationQuality = .none
        context.draw(top, in: CGRect(x: 0, y: tailHeight, width: top.width, height: top.height))
        context.draw(tail, in: CGRect(x: 0, y: 0, width: tail.width, height: tail.height))
        guard let combined = context.makeImage() else { return update(.limit) }
        self.image = combined; self.previous = next
        fixedBottom = footer; position = newPosition; furthest = newPosition; count += 1
        return update(.appended)
    }
    func result() -> CGImage? { image }
    private func update(_ outcome: Outcome) -> Update {
        let preview: CGImage?
        if [.started, .appended].contains(outcome), let image {
            let scale = min(1, 260.0 / Double(image.width), 700.0 / Double(image.height))
            let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.interpolationQuality = .medium
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            preview = context?.makeImage()
        } else { preview = nil }
        return Update(outcome: outcome, height: image?.height ?? 0, count: count, preview: preview)
    }

    private static func displacement(_ previous: CGImage, _ next: CGImage, a: GrayRows, b: GrayRows) -> Int? {
        // Register the central content so window borders and sticky navigation do not dominate.
        let rect = CGRect(x: previous.width / 12, y: previous.height / 6,
                          width: previous.width * 5 / 6, height: previous.height * 2 / 3)
        guard let target = next.cropping(to: rect), let reference = previous.cropping(to: rect) else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
        do { try VNImageRequestHandler(cgImage: reference).perform([request]) } catch { return nil }
        guard let observation = request.results?.first,
              abs(observation.alignmentTransform.tx) < 3,
              observation.alignmentTransform.ty.isFinite else { return nil }
        let estimate = Int(abs(observation.alignmentTransform.ty).rounded())
        guard estimate < previous.height * 2 / 3 else { return nil }
        // Verify orientation and subpixel rounding against the actual overlap, not just Vision's score.
        let candidates = Set((-2...2).flatMap { delta in [estimate + delta, -estimate + delta] })
        let scores = candidates.filter { abs($0) < previous.height * 2 / 3 }.map { shift in
            (shift, a.difference(b, shift: shift, trim: previous.height / 6))
        }.sorted { $0.1 < $1.1 }
        guard let best = scores.first, best.1 < 6 else { return nil }
        if abs(best.0) <= 1 { return best.1 < 1 ? 0 : nil }
        let still = a.difference(b, shift: 0, trim: previous.height / 6)
        guard best.1 < still * 0.45, a.hasDetail(shift: best.0) else { return nil }
        return best.0
    }
}

/// Small horizontal samples but original-height rows: alignment keeps native pixel precision.
private struct GrayRows {
    let width = 96
    let height: Int
    let bytes: [UInt8]
    init?(_ image: CGImage) {
        height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }
    func difference(_ other: GrayRows, shift: Int, trim: Int) -> Double {
        let start = max(trim, -shift + trim), end = min(height - trim, height - shift - trim)
        guard end - start >= 24 else { return .infinity }
        var total = 0, count = 0
        for y in stride(from: start, to: end, by: max(1, (end - start) / 100)) {
            for x in 8..<(width - 8) {
                total += abs(Int(bytes[(y + shift) * width + x]) - Int(other.bytes[y * width + x])); count += 1
            }
        }
        return Double(total) / Double(max(1, count))
    }
    func hasDetail(shift: Int) -> Bool {
        var edges = 0
        let start = height / 5, end = height * 4 / 5
        for y in stride(from: start, to: end, by: max(1, height / 150)) {
            for x in 9..<(width - 8) where abs(Int(bytes[y * width + x]) - Int(bytes[y * width + x - 1])) > 12 { edges += 1 }
        }
        return edges > 30
    }
    func fixedBottomRows(_ other: GrayRows) -> Int {
        var rows = 0
        for y in stride(from: height - 1, through: height * 4 / 5, by: -1) {
            let error = (8..<(width - 8)).reduce(0) { $0 + abs(Int(bytes[y * width + $1]) - Int(other.bytes[y * width + $1])) }
            if Double(error) / Double(width - 16) > 1 { break }
            rows += 1
        }
        return rows >= 8 ? rows : 0
    }
}
