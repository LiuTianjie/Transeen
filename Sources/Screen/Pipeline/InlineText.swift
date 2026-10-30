import CoreGraphics
import Foundation

/// Keep the visual runs inside a line. In particular a code chip is an
/// obstacle with its original pixels, not text to erase and move into prose.
enum InlineText {
    private struct Piece {
        var text: String
        var box: CGRect
        var literal: Bool
        var ink: LineInk?
    }

    static func measure(_ line: RecognizedLine, pixels: PixelImage, scale: CGFloat,
                        verticalBounds: ClosedRange<CGFloat>,
                        measure: (String, CGRect, ClosedRange<CGFloat>) -> MeasuredLine?) -> [MeasuredLine]? {
        var spans = line.spans
        guard !spans.isEmpty else { return nil }
        // Vision gives a word's whole box to a part it cannot place, such as the full stop
        // after `CHANGELOG.md`. The gap in the ink says where the two meet.
        for index in spans.indices.dropFirst()
        where spans[index].box.minX < spans[index - 1].box.maxX - scale && spans[index].text.allSatisfy(\.isPunctuation) {
            let previous = spans[index - 1].box, both = previous.union(spans[index].box)
            guard let ink = InkAnalyzer.measure(pixels, box: both, verticalBounds: verticalBounds, horizontalBounds: (both.minX - scale)...(both.maxX + scale)),
                  ink.blobs.count >= 2, let last = ink.blobs.last, last.maxX - last.minX < both.height * 0.5 else { continue }
            let cut = (ink.blobs[ink.blobs.count - 2].maxX + last.minX) / 2
            guard cut > previous.minX, cut < both.maxX else { continue }
            spans[index - 1].box = CGRect(x: previous.minX, y: previous.minY, width: cut - previous.minX, height: previous.height)
            spans[index].box = CGRect(x: cut, y: spans[index].box.minY, width: both.maxX - cut, height: spans[index].box.height)
        }
        // A missing or overlapping Vision word box is not enough evidence to
        // cut up a sentence. Fall back to the ordinary line measurement.
        let reconstructed = spans.enumerated().map { ($0.offset == 0 ? "" : $0.element.separator) + $0.element.text }.joined()
        guard reconstructed == line.text else { return nil }

        var pieces: [Piece] = []
        for index in spans.indices {
            let span = spans[index]
            let left = index == 0 ? line.box.minX - scale : (spans[index - 1].box.maxX + span.box.minX) / 2
            let right = index == spans.count - 1 ? line.box.maxX + scale : (span.box.maxX + spans[index + 1].box.minX) / 2
            guard left < right else { return nil }
            let ink = InkAnalyzer.measure(pixels, box: span.box, verticalBounds: verticalBounds, horizontalBounds: left...right)
            let next = Piece(text: span.text, box: span.box, literal: span.literal, ink: ink)
            if let previous = pieces.last, previous.literal == next.literal,
               compatible(previous.ink, next.ink), span.box.minX - previous.box.maxX < line.box.height * 1.5 {
                pieces[pieces.count - 1].text += span.separator + span.text
                pieces[pieces.count - 1].box = previous.box.union(span.box)
                if pieces[pieces.count - 1].ink == nil { pieces[pieces.count - 1].ink = ink }
            } else {
                pieces.append(next)
            }
        }
        guard pieces.count > 1 || pieces.first?.literal == true else { return nil }
        for index in pieces.indices.dropFirst() {
            guard pieces[index].box.minX >= pieces[index - 1].box.maxX - scale else { return nil }
        }
        var measured: [MeasuredLine] = []
        for index in pieces.indices {
            let piece = pieces[index]
            let left = index == 0 ? line.box.minX - scale : (pieces[index - 1].box.maxX + piece.box.minX) / 2
            let right = index == pieces.count - 1 ? line.box.maxX + scale : (piece.box.maxX + pieces[index + 1].box.minX) / 2
            guard left < right, var run = measure(piece.text, piece.box, left...right) else { return nil }
            run.inlineBounds = left...right
            // Short identifiers such as `timeout` have no lexical punctuation.
            // A distinct paper plus code-like ink is evidence of an inline chip;
            // ordinary monospaced prose and coloured links still translate.
            let codeInk = codeInk(run.style)
            // A pill taller or wider than the word's box puts its own edge into the rim the
            // background is read from, which then looks like a picture. Inside the box it is one colour.
            var own: RGB?
            switch run.ink.background {
            case .flat(let colour): own = colour
            default: own = codeInk && !piece.text.contains(" ") ? interiorPaper(piece.box, in: pixels) : nil
            }
            let separatePaper = own.map { own in
                pieces.enumerated().contains { peer, value in
                    guard abs(peer - index) == 1, let ink = value.ink, case .flat(let paper) = ink.background else { return false }
                    return own.distance(to: paper) > 14
                }
            } ?? false
            run.protectedLiteral = piece.literal || (codeInk && separatePaper && !piece.text.contains(" "))
            if run.protectedLiteral, let own { run.ink.background = .flat(own) }
            run.startsListItem = index == 0 && line.startsListItem
            measured.append(run)
        }
        // Without a chip the runs are one sentence whose words merely measure a little differently:
        // anti-aliasing makes short words read lighter. Split, they would be translated word by word.
        guard measured.contains(where: \.protectedLiteral) else { return nil }
        return measured
    }

    static func codeInk(_ style: TextStyle) -> Bool {
        style.face == .mono || max(style.color.r, style.color.g, style.color.b) - min(style.color.r, style.color.g, style.color.b) > 35
    }

    /// The colour most of a word's box is filled with, when that is nearly all of it.
    static func interiorPaper(_ box: CGRect, in pixels: PixelImage) -> RGB? {
        let x0 = max(0, Int(box.minX + 1)), x1 = min(pixels.width, Int(box.maxX - 1))
        let y0 = max(0, Int(box.minY + 1)), y1 = min(pixels.height, Int(box.maxY - 1))
        guard x0 < x1, y0 < y1 else { return nil }
        var bins: [Int: (count: Int, sum: RGB)] = [:]
        for y in y0..<y1 {
            for x in x0..<x1 {
                let c = pixels[x, y]
                let key = (Int(c.r) >> 4) << 8 | (Int(c.g) >> 4) << 4 | (Int(c.b) >> 4)
                let bin = bins[key] ?? (0, RGB(r: 0, g: 0, b: 0))
                bins[key] = (bin.count + 1, bin.sum + c)
            }
        }
        guard let top = bins.values.max(by: { $0.count < $1.count }) else { return nil }
        let mode = top.sum * (1 / Float(top.count))
        var close = 0, sum = RGB(r: 0, g: 0, b: 0)
        for y in y0..<y1 { for x in x0..<x1 where pixels[x, y].distance(to: mode) <= 10 { close += 1; sum = sum + pixels[x, y] } }
        // Glyphs and their anti-aliased edges cover well under half of a word's box.
        guard close * 2 >= (x1 - x0) * (y1 - y0) else { return nil }
        return sum * (1 / Float(close))
    }

    private static func compatible(_ a: LineInk?, _ b: LineInk?) -> Bool {
        guard let a, let b else { return true }
        // Photographs do not provide a reliable per-word paper; a word in another colour
        // altogether (red code in a pill whose edge spoils the paper) still stands apart.
        guard case .flat(let paperA) = a.background, case .flat(let paperB) = b.background else { return a.color.distance(to: b.color) <= 80 }
        return paperA.distance(to: paperB) <= 14 && a.color.distance(to: b.color) <= 28
    }
}
