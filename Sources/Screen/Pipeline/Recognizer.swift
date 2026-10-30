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
        let lines = try confirmed(tiled(image, languages: languages), in: image, languages: languages)
        return try withHanRestored(lines, in: image, languages: languages)
    }

    private static let hanLanguages = ["zh-Hans", "zh-Hant", "ja-JP", "ja", "ko-KR", "ko"]

    /// Read with Latin first, a few Han words inside an English sentence come back as
    /// Latin garbage ("defaulting to 简体中文." as "defaulting to iǻ1##X."). Those
    /// stretches are read again with Han first.
    static func withHanRestored(_ lines: [RecognizedLine], in image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let han = languages.filter { hanLanguages.contains($0) }
        guard !han.isEmpty else { return lines }
        let hanFirst = han + languages.filter { !han.contains($0) }
        let suspects = lines.indices.filter { index in
            lines[index].spans.contains { isGarbledHan($0.text) } && StyleEstimator.hanShare(lines[index].text) < 0.5
        }
        guard !suspects.isEmpty else { return lines }
        var restored = [RecognizedLine?](repeating: nil, count: suspects.count)
        let failure = Mutex<(any Error)?>(nil)
        restored.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let results = buffer
            DispatchQueue.concurrentPerform(iterations: suspects.count) { index in
                do { results[index] = try restoringHan(lines[suspects[index]], in: image, languages: hanFirst) } catch { failure.withLock { $0 = error } }
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }
        var result = lines
        for (index, line) in zip(suspects, restored) { if let line { result[index] = line } }
        return result
    }

    /// A word no reading of English looks like: a letter from another script, or a symbol
    /// in it ("E*li7", "(#1)"). Only a suspect: a Han reading of the place decides.
    static func isGarbledHan(_ word: String) -> Bool {
        let scalars = word.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        if letters.contains(where: { $0.value > 0x24F && !(0x1E00...0x1EFF).contains($0.value) && !StyleEstimator.isHan($0) }) { return true }
        return word.count >= 2 && scalars.contains { "#*+=~^|{}<>¦".unicodeScalars.contains($0) }
    }

    private static func restoringHan(_ line: RecognizedLine, in image: CGImage, languages: [String]) throws -> RecognizedLine? {
        var spans = line.spans
        var changed = false
        var index = 0
        while index < spans.count {
            defer { index += 1 }
            guard isGarbledHan(spans[index].text) else { continue }
            // A misread stretch is often several "words" long ("E*li7 8 2L" for 已翻译 8 处), and the
            // recogniser reads a Han word whole only with enough around it: the fullest of a few readings.
            var best: (text: String, box: CGRect, han: Int)?
            for reach in [(1, 2), (2, 3)] {
                let first = max(0, index - reach.0), last = min(spans.count - 1, index + reach.1)
                let window = spans[first...last].reduce(CGRect.null) { $0.union($1.box) }
                let margin = line.box.height * 0.4
                let area = window.insetBy(dx: -margin * 0.5, dy: -margin)
                    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
                guard area.width >= 2, area.height >= 2, let piece = image.cropping(to: area) else { continue }
                for factor in [CGFloat(2), 1] {
                    for run in try hanRuns(in: piece, magnified: factor, languages: languages) {
                        let box = run.box.offsetBy(dx: area.minX, dy: area.minY)
                        guard box.intersects(spans[index].box.insetBy(dx: 0, dy: -line.box.height)) else { continue }
                        let han = run.text.unicodeScalars.filter { StyleEstimator.isHan($0) }.count
                        if han > best?.han ?? 0 { best = (run.text, box, han) }
                    }
                }
            }
            guard let run = best else { continue }
            let covered = spans.indices.filter { spans[$0].box.midX >= run.box.minX - 2 && spans[$0].box.midX <= run.box.maxX + 2 }
            guard let start = covered.first, let end = covered.last, covered.contains(index) else { continue }
            // Punctuation of the sentence that the misread word carried along.
            let tail = String(spans[end].text.reversed().prefix { ".,;:!?".contains($0) }.reversed())
            let text = run.text.hasSuffix(tail) ? run.text : run.text + tail
            let merged = spans[start...end].reduce(CGRect.null) { $0.union($1.box) }
            spans.replaceSubrange(start...end, with: [Span(text: text, box: merged, separator: spans[start].separator, literal: false)])
            index = start
            changed = true
        }
        guard changed else { return nil }
        var line = line
        line.spans = spans
        line.text = joined(spans)
        return line
    }

    /// Stretches of Han in `piece`, read Han first at `factor` times its size, with their boxes in its pixels.
    private static func hanRuns(in piece: CGImage, magnified factor: CGFloat, languages: [String]) throws -> [(text: String, box: CGRect)] {
        let width = Int(CGFloat(piece.width) * factor), height = Int(CGFloat(piece.height) * factor)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.interpolationQuality = .high
        context.draw(piece, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let magnified = context.makeImage() else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: magnified, options: [:]).perform([request])
        let pattern = #"[(（「《]?\p{Han}(?:[\p{Han}\d ]*\p{Han})?[)）」》]?"#
        var runs: [(text: String, box: CGRect)] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            var searchStart = string.startIndex
            while let range = string.range(of: pattern, options: .regularExpression, range: searchStart..<string.endIndex) {
                searchStart = range.upperBound
                let text = String(string[range])
                guard text.unicodeScalars.filter({ StyleEstimator.isHan($0) }).count >= 2,
                      let bounds = try candidate.boundingBox(for: range)?.boundingBox else { continue }
                let box = CGRect(x: bounds.minX * CGFloat(piece.width), y: (1 - bounds.maxY) * CGFloat(piece.height),
                                 width: bounds.width * CGFloat(piece.width), height: bounds.height * CGFloat(piece.height))
                runs.append((text.replacingOccurrences(of: " ", with: ""), box))
            }
        }
        return runs
    }
    typealias Span = RecognizedLine.Span

    /// A line the recogniser was unsure of is read again, magnified. Type reads the same
    /// twice; a picture read as text (a row of thumbnails as "望开！") reads differently or not at all.
    static func confirmed(_ lines: [RecognizedLine], in image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let doubtful = lines.indices.filter { lines[$0].confidence < 1 }
        guard !doubtful.isEmpty else { return lines }
        var verdicts = [RecognizedLine?](repeating: nil, count: doubtful.count)
        let failure = Mutex<(any Error)?>(nil)
        verdicts.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let results = buffer
            DispatchQueue.concurrentPerform(iterations: doubtful.count) { index in
                do { results[index] = try reread(lines[doubtful[index]], in: image, languages: languages) } catch { failure.withLock { $0 = error } }
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }
        var result = lines
        for (index, line) in zip(doubtful, verdicts).reversed() {
            if let line { result[index] = line } else { result.remove(at: index) }
        }
        return result
    }

    static let rereadMagnification: CGFloat = 2

    /// The line as a magnified second reading confirms it, a clearer reading of it, or nil when it is not text.
    private static func reread(_ line: RecognizedLine, in image: CGImage, languages: [String]) throws -> RecognizedLine? {
        let margin = line.box.height * 0.6
        let area = line.box.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard area.width >= 2, area.height >= 2, let piece = image.cropping(to: area) else { return line }
        let factor = rereadMagnification
        let width = Int(CGFloat(piece.width) * factor), height = Int(CGFloat(piece.height) * factor)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return line }
        context.interpolationQuality = .high
        context.draw(piece, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let magnified = context.makeImage() else { return line }
        func back(_ box: CGRect) -> CGRect {
            CGRect(x: area.minX + box.minX / factor, y: area.minY + box.minY / factor, width: box.width / factor, height: box.height / factor)
        }
        let readings = try scan(magnified, languages: languages).map { reading in
            var reading = reading
            reading.box = back(reading.box)
            reading.spans = reading.spans.map { span in var span = span; span.box = back(span.box); return span }
            return reading
        }.filter { reading in
            let both = reading.box.intersection(line.box)
            return !both.isNull && both.width > min(reading.box.width, line.box.width) * 0.5
                && both.height > min(reading.box.height, line.box.height) * 0.5
        }
        func letters(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        if readings.contains(where: { letters($0.text) == letters(line.text) }) { return line }
        // Small type the first reading garbled is read cleanly once magnified.
        if readings.count == 1, let clear = readings.first, clear.confidence >= 1,
           clear.box.width >= line.box.width * 0.8 { return clear }
        return nil
    }

    private static func tiled(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
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
