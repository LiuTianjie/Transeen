import CoreGraphics
import Foundation
import Synchronization
import Vision

/// One line as the recogniser reports it. Nothing is merged here: whether two
/// fragments on a row belong together is decided later, from the pixels between them.
struct RecognizedLine: Sendable {
    var text: String
    /// Picture pixels, top-left origin.
    var box: CGRect
    var confidence: Float
    var startsListItem: Bool
    var spans: [Span] = []

    struct Span: Sendable {
        var text: String
        var box: CGRect
        var separator: String
        var literal: Bool
    }
}

enum Recognizer {
    /// Vision downsamples by pixel dimensions, even for a Retina screenshot.
    static let largePicture: CGFloat = 1600

    /// `scale` is picture pixels per point: on a Retina capture the type is
    /// twice as many pixels tall and survives the recogniser's scaling down.
    static func recognize(_ image: CGImage, scale: CGFloat, languages: [String]) throws -> [RecognizedLine] {
        let initial = try scan(image, languages: languages)
        guard CGFloat(max(image.width, image.height)) > largePicture else { return initial }
        // Vision scales a large picture down and loses small type. Read every
        // column of text again at its own resolution, in tiles that overlap
        // from top to bottom. A line is never cut at an arbitrary vertical edge.
        let width = CGFloat(image.width), height = CGFloat(image.height)
        struct Tile { var crop: CGRect; var startY: CGFloat; var endY: CGFloat }
        var tiles: [Tile] = []
        let core: CGFloat = 1280
        for column in columns(width: width, initial: initial) {
            let left = max(0, floor(column.0 - 16)), right = min(width, ceil(column.1 + 16))
            for start in stride(from: CGFloat(0), to: height, by: core) {
                let end = min(height, start + core)
                let top = max(0, start - 128), bottom = min(height, end + 128)
                tiles.append(Tile(crop: CGRect(x: left, y: top, width: right - left, height: bottom - top), startY: start, endY: end))
            }
        }
        var perTile = [[RecognizedLine]](repeating: [], count: tiles.count)
        let failure = Mutex<(any Error)?>(nil)
        let workTiles = tiles
        perTile.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let results = buffer
            DispatchQueue.concurrentPerform(iterations: workTiles.count) { index in
                let tile = workTiles[index]
                guard let crop = image.cropping(to: tile.crop) else { return }
                do {
                    results[index] = try scan(crop, languages: languages).compactMap { line in
                        var moved = line
                        moved.box = line.box.offsetBy(dx: tile.crop.minX, dy: tile.crop.minY)
                        moved.spans = line.spans.map { span in
                            var moved = span
                            moved.box = span.box.offsetBy(dx: tile.crop.minX, dy: tile.crop.minY)
                            return moved
                        }
                        // Each line belongs to the tile its middle lies in.
                        return moved.box.midY >= tile.startY && moved.box.midY < tile.endY ? moved : nil
                    }
                } catch {
                    failure.withLock { $0 = error }
                }
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }
        var refined = perTile.flatMap { $0 }
        // What the first reading found and the tiles did not: a line wider than its tile, mostly.
        for line in initial {
            let matched = refined.contains { other in
                let both = line.box.intersection(other.box)
                return !both.isNull && both.height > min(line.box.height, other.box.height) * 0.4
                    && both.width > min(line.box.width, other.box.width) * 0.4
            }
            if !matched { refined.append(line) }
        }
        return refined
    }

    /// The stretches from left to right that hold text. With nothing found the whole width is one.
    static func columns(width: CGFloat, initial: [RecognizedLine]) -> [(CGFloat, CGFloat)] {
        var columns: [(CGFloat, CGFloat)] = initial.isEmpty ? [(0, width)] : []
        for interval in initial.map({ ($0.box.minX, $0.box.maxX) }).sorted(by: { $0.0 < $1.0 }) {
            if let last = columns.last, interval.0 <= last.1 + 16 {
                columns[columns.count - 1].1 = max(last.1, interval.1)
            } else {
                columns.append(interval)
            }
        }
        return columns
    }

    private static func scan(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages.filter { !$0.isEmpty }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let raw = candidate.string
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var contentRange = raw.startIndex..<raw.endIndex
            var box = observation.boundingBox
            let bullet = raw.range(of: #"^\s*[•●◦▪‣·]\s+"#, options: .regularExpression)
            // A leading icon read as a letter or a digit stays a picture.
            if let space = raw.firstIndex(of: " ") {
                let prefix = String(raw[..<space])
                let rest = raw.index(after: space)..<raw.endIndex
                if isLikelyIconPrefix(prefix, before: raw[rest]) || bullet != nil, raw[rest].count >= 2,
                   let suffix = try? candidate.boundingBox(for: rest) {
                    text = String(raw[rest]).trimmingCharacters(in: .whitespaces)
                    contentRange = rest
                    box = suffix.boundingBox
                }
            }
            // An emoji or flag before a word comes back as a bullet glued to it ("•France").
            if bullet == nil, contentRange.lowerBound == raw.startIndex,
               let glued = raw.range(of: #"^[•●◦▪‣](?=\p{L})"#, options: .regularExpression),
               raw[glued.upperBound...].count >= 2,
               let suffix = try? candidate.boundingBox(for: glued.upperBound..<raw.endIndex) {
                contentRange = glued.upperBound..<raw.endIndex
                text = String(raw[contentRange]).trimmingCharacters(in: .whitespaces)
                box = suffix.boundingBox
            }
            // A disclosure arrow at the end ("Ran 2 commands ›") is an icon, not a word to translate.
            if let space = raw[contentRange].lastIndex(of: " "),
               ["›", ">", "»", "〉", "❯"].contains(raw[raw.index(after: space)..<contentRange.upperBound].trimmingCharacters(in: .whitespaces)),
               raw[contentRange.lowerBound..<space].trimmingCharacters(in: .whitespaces).count >= 2,
               let kept = try? candidate.boundingBox(for: contentRange.lowerBound..<space) {
                contentRange = contentRange.lowerBound..<space
                text = String(raw[contentRange]).trimmingCharacters(in: .whitespaces)
                box = kept.boundingBox
            }
            guard shouldKeep(text, confidence: candidate.confidence) else { return nil }
            let literals = CodeText.literalRanges(in: raw)
            let words = (try? NSRegularExpression(pattern: #"\S+"#))?.matches(in: raw, range: NSRange(contentRange, in: raw))
                .compactMap { Range($0.range, in: raw) } ?? []
            var spans: [RecognizedLine.Span] = []
            var previousEnd = contentRange.lowerBound
            for word in words {
                let boundaries = Set([word.lowerBound, word.upperBound] + literals.flatMap { [$0.lowerBound, $0.upperBound] }
                    .filter { $0 > word.lowerBound && $0 < word.upperBound }).sorted()
                for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                    let range = start..<end
                    guard let bounds = try? candidate.boundingBox(for: range) else { continue }
                    let separator = raw[previousEnd..<start].contains(where: { $0.isWhitespace }) ? " " : ""
                    spans.append(.init(text: String(raw[range]), box: pixels(bounds.boundingBox), separator: separator,
                        literal: literals.contains { $0.lowerBound <= start && $0.upperBound >= end }))
                    previousEnd = end
                }
            }
            if !spans.isEmpty, joined(spans) == text {
                spans = corrected(spans)
                text = joined(spans)
            } else {
                text = text.split(separator: " ", omittingEmptySubsequences: false).map { correctedWord(String($0)) }.joined(separator: " ")
            }
            return RecognizedLine(text: text, box: pixels(box), confidence: candidate.confidence,
                startsListItem: bullet != nil, spans: spans)
        }
    }

    static func joined(_ spans: [RecognizedLine.Span]) -> String {
        spans.enumerated().map { ($0.offset == 0 ? "" : $0.element.separator) + $0.element.text }.joined()
    }

    /// Words the recogniser misreads in interface type, where I and l look alike.
    static func correctedWord(_ word: String) -> String {
        // I'll, I'm, I've, I'd
        // The l and I of interface type look alike in any of the three places: l'il, I'Il, l'll.
        if let match = word.range(of: #"^[lI]['’](?:[lIi][lI]|m|ve|d)\b"#, options: .regularExpression) {
            let apostrophe = word[word.index(after: word.startIndex)]
            let tail = word[word.index(word.startIndex, offsetBy: 2)..<match.upperBound]
            return "I" + String(apostrophe) + (tail.count == 2 ? "ll" : String(tail)) + word[match.upperBound...]
        }
        if word == "l" { return "I" }
        // A sentence run into the next one's I: "text.l should".
        if let dot = word.range(of: #"[a-z]{2}\.l$"#, options: .regularExpression) { return word[..<dot.upperBound].dropLast() + " I" }
        // CI, UI, API, CLI, GUI, URI with their last I read as l, before any punctuation.
        let acronyms = ["Cl": "CI", "Ul": "UI", "APl": "API", "CLl": "CLI", "GUl": "GUI", "URl": "URI"]
        let letters = word.prefix { $0.isLetter }
        if let fixed = acronyms[String(letters)] { return fixed + word.dropFirst(letters.count) }
        return word
    }

    /// `corrected(_:)` on every word, and a file name split after its dot ("project. yml") joined again, as a literal.
    static func corrected(_ spans: [RecognizedLine.Span]) -> [RecognizedLine.Span] {
        var result: [RecognizedLine.Span] = []
        for var span in spans {
            span.text = correctedWord(span.text)
            if let last = result.last, last.text.count >= 2, last.text.hasSuffix("."), span.separator == " ",
               last.text.dropLast().last.map({ $0.isLetter || $0.isNumber }) == true,
               CodeText.isFileName(last.text + span.text.prefix { $0.isLetter }) {
                result[result.count - 1].text += span.text
                result[result.count - 1].box = last.box.union(span.box)
                result[result.count - 1].literal = true
                continue
            }
            if !span.literal, CodeText.isFileName(span.text) { span.literal = true }
            result.append(span)
        }
        return result
    }

    /// Keep short labels and numbers without turning every icon-shaped glyph
    /// into text. The recogniser's confidence only decides the ambiguous cases:
    /// a single character, a bare number. Ordinary words are always kept.
    static func shouldKeep(_ text: String, confidence: Float) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty else { return false }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        if letters.count >= 2 { return true } // "OK", "AI", "设置"
        if let letter = letters.first, letters.count == 1, letter.value > 0x7f { return confidence >= 0.45 }
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }
        let numericPunctuation = CharacterSet(charactersIn: ".,:%+-/年月日时分秒")
        if !digits.isEmpty,
           scalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) || numericPunctuation.contains($0) }) {
            return confidence >= 0.60
        }
        return false
    }

    /// `next` is the word after the prefix: a number before a lowercase word is a count ("2 minutes ago").
    static func isLikelyIconPrefix(_ prefix: String, before next: Substring = "") -> Bool {
        let scalars = prefix.unicodeScalars
        guard !scalars.isEmpty else { return false }
        if prefix.allSatisfy(\.isNumber), next.first?.isLowercase == true { return false }
        if scalars.count == 1 {
            let scalar = scalars[scalars.startIndex]
            // A/I are real words; a lone digit, symbol or other ASCII letter is
            // commonly the recogniser's reading of a sidebar icon.
            return !["A", "a", "I", "i"].contains(prefix)
                && (scalar.isASCII || CharacterSet.symbols.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar))
        }
        return scalars.allSatisfy { CharacterSet.decimalDigits.contains($0)
            || CharacterSet.symbols.contains($0) || CharacterSet.punctuationCharacters.contains($0) }
    }
}
