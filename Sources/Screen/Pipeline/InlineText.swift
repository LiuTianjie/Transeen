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
        let spans = line.spans
        guard !spans.isEmpty else { return nil }
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
            let codeInk = run.style.face == .mono || max(run.style.color.r, run.style.color.g, run.style.color.b)
                - min(run.style.color.r, run.style.color.g, run.style.color.b) > 35
            let separatePaper: Bool = {
                guard case .flat(let own) = run.ink.background else { return false }
                return pieces.enumerated().contains { peer, value in
                    guard abs(peer - index) == 1, let ink = value.ink, case .flat(let paper) = ink.background else { return false }
                    return own.distance(to: paper) > 14
                }
            }()
            run.protectedLiteral = piece.literal || (codeInk && separatePaper && !piece.text.contains(" "))
            run.startsListItem = index == 0 && line.startsListItem
            measured.append(run)
        }
        return measured
    }

    private static func compatible(_ a: LineInk?, _ b: LineInk?) -> Bool {
        guard let a, let b else { return true }
        // Photographs do not provide a reliable per-word style boundary.
        guard case .flat(let paperA) = a.background, case .flat(let paperB) = b.background else { return true }
        return paperA.distance(to: paperB) <= 14 && a.color.distance(to: b.color) <= 28
    }
}
