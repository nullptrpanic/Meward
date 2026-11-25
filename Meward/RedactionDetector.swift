import UIKit
import Vision

struct Redaction: Identifiable, Equatable {
    enum Kind: String { case phone = "Mobile number", identity = "ID number", name = "Name", manual = "Manual cover" }

    static let imageBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let id = UUID()
    let kind: Kind
    // Fractions of the upright image, with the origin at the top left.
    var rect: CGRect
    var needsReview: Bool
    var isEnabled = true

    init(_ kind: Kind, rect: CGRect, needsReview: Bool = false) {
        self.kind = kind
        self.rect = rect.standardized.intersection(Self.imageBounds)
        self.needsReview = needsReview
    }
}

struct OCRFragment {
    let text: String
    let rect: CGRect
    var candidate: VNRecognizedText?

    func bounds(for range: NSRange) -> CGRect {
        guard let candidate, let indices = Range(range, in: text),
              let box = try? candidate.boundingBox(for: indices) else { return rect }
        let cropped = Self.upright(box.boundingBox)
        return cropped.isEmpty ? rect : cropped
    }

    static func upright(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}

// Vision sometimes splits a label, or the groups of digits in one number, into separate observations.
private struct OCRRow {
    var text = ""
    var rect = CGRect.null
    var fragments: [(NSRange, OCRFragment)] = []

    mutating func append(_ fragment: OCRFragment) {
        if let (_, previous) = fragments.last {
            // Vision may split one Chinese name into adjacent observations.
            let adjacentHan = previous.text.unicodeScalars.last?.properties.isIdeographic == true
                && fragment.text.unicodeScalars.first?.properties.isIdeographic == true
            let glyphWidth = min(previous.rect.width / CGFloat(previous.text.count),
                                 fragment.rect.width / CGFloat(fragment.text.count))
            if !adjacentHan || fragment.rect.minX - previous.rect.maxX > glyphWidth * 0.55 { text.append(" ") }
        }
        fragments.append((NSRange(location: text.utf16.count, length: fragment.text.utf16.count), fragment))
        text.append(fragment.text)
        rect = rect.union(fragment.rect)
    }

    func bounds(for range: NSRange) -> CGRect {
        var box = CGRect.null
        for (span, fragment) in fragments {
            let overlap = NSIntersectionRange(span, range)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - span.location, length: overlap.length)
            box = box.union(fragment.bounds(for: local))
        }
        return box
    }
}

enum RedactionDetector {
    private static let numberLabels: [(Redaction.Kind, NSRegularExpression)] = [
        (.identity, regex(#"(?:公\s*民\s*)?身\s*[份分]\s*(?:[证證]\s*)?(?:[号號]\s*[码碼]?)?|[证證]\s*件\s*[号號]\s*[码碼]?"#)),
        (.phone, regex(#"手\s*[机機]\s*(?:[号號]\s*[码碼]?)?|(?:联\s*系\s*)?[电電]\s*[话話]"#))
    ]
    private static let separator = #"[\s\-‐‑–—]*"#
    private static let phone = regex(#"(?<!\d)(?:(?:[+＋]?[8８][6６]|[0０]{2}[8８][6６])"# + separator
        + #")?[1１]"# + separator + #"[3-9３-９](?:"# + separator + #"\d){9}(?!\d)"#)
    private static let identity = regex(#"(?<!\d)\d(?:"# + separator + #"\d){16}"# + separator + #"[\dXxＸｘ](?![\dXxＸｘ])"#)
    private static let numberToken = regex(#"[+＋]?[\dA-Za-zＡ-Ｚａ-ｚ]+(?:[\s\-‐‑–—]+[\dA-Za-zＡ-Ｚａ-ｚ]+)*"#)
    private static let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：|，,；;"))

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // These are fixed expressions compiled once, never user input.
        try! NSRegularExpression(pattern: pattern)
    }

    static func scan(_ photo: EditorPhoto, request: VNRecognizeTextRequest = VNRecognizeTextRequest()) throws -> [Redaction] {
        let original = try photo.fullImage()
        guard let image = original.cgImage else { throw PhotoError.unreadable }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.005
        let handler = VNImageRequestHandler(cgImage: image, orientation: original.imageOrientation.exifOrientation)
        try handler.perform([request])
        let fragments = (request.results ?? []).compactMap { item -> OCRFragment? in
            guard let candidate = item.topCandidates(1).first else { return nil }
            return OCRFragment(text: candidate.string, rect: OCRFragment.upright(item.boundingBox), candidate: candidate)
        }
        return try covers(in: fragments)
    }

    static func covers(in fragments: [OCRFragment]) throws -> [Redaction] {
        let rows = makeRows(fragments)
        guard !rows.isEmpty else { return [] }
        let recognizer = try ChineseNameRecognizer()
        var result: [Redaction] = []
        func add(_ kind: Redaction.Kind, _ range: NSRange, in row: OCRRow, review: Bool) {
            let box = row.bounds(for: range)
            guard !box.isEmpty else { return }
            // Include glyph edges and displaced strokes outside Vision's tight bounding boxes.
            let rect = box.insetBy(dx: -max(0.002, box.height * 0.13), dy: -max(0.002, box.height * 0.16))
            let cover = Redaction(kind, rect: rect, needsReview: review)
            if !result.contains(where: { $0.kind == kind && $0.rect == cover.rect }) { result.append(cover) }
        }

        for row in rows {
            let ns = row.text as NSString
            let full = NSRange(location: 0, length: ns.length)
            let fields = numberLabels.flatMap { kind, re in
                re.matches(in: row.text, range: full).map { (kind: kind, range: $0.range) }
            }.sorted { $0.range.location < $1.range.location }
            var handled: [NSRange] = []
            for (i, field) in fields.enumerated() {
                let start = NSMaxRange(field.range)
                let end = i + 1 < fields.count ? fields[i + 1].range.location : ns.length
                var valueRow = row
                var value = trimmed(NSRange(location: start, length: end - start), in: ns)
                let onSameRow = value.length > 0
                if !onSameRow {
                    guard i == fields.count - 1,
                          let next = adjacentValue(below: row, rows: rows, label: row.bounds(for: field.range)) else { continue }
                    valueRow = rows[next]
                    value = trimmed(NSRange(location: 0, length: valueRow.text.utf16.count), in: valueRow.text as NSString)
                }
                let valueText = valueRow.text as NSString
                guard valueText.substring(with: value).filter(\.isNumber).count >= 3 else { continue }
                let pattern = field.kind == .identity ? identity : phone
                let match = pattern.firstMatch(in: valueRow.text, range: value)
                guard let number = match?.range ?? damagedNumber(in: value, text: valueRow.text,
                                                                  kind: field.kind, inline: onSameRow) else { continue }
                let digits = valueText.substring(with: number)
                add(field.kind, number, in: valueRow, review: match == nil || (field.kind == .identity && !validID(digits)))
                if onSameRow {
                    handled.append(number)
                }
            }
            for match in identity.matches(in: row.text, range: full) where !overlaps(match.range, handled) {
                let value = ns.substring(with: match.range)
                let valid = validID(value)
                if valid || hasBirthDate(value) { add(.identity, match.range, in: row, review: !valid) }
                handled.append(match.range)
            }
            for match in phone.matches(in: row.text, range: full) where !overlaps(match.range, handled) {
                add(.phone, match.range, in: row, review: false)
            }
            for prediction in recognizer.ranges(in: row.text) {
                add(.name, prediction, in: row, review: true)
            }
        }
        return result
    }

    private static func makeRows(_ fragments: [OCRFragment]) -> [OCRRow] {
        var bands: [[OCRFragment]] = []
        for f in fragments.sorted(by: { $0.rect.midY < $1.rect.midY }) where !f.text.isEmpty && !f.rect.isEmpty {
            if let first = bands.last?.first, abs(f.rect.midY - first.rect.midY) < min(f.rect.height, first.rect.height) * 0.55 {
                bands[bands.count - 1].append(f)
            } else { bands.append([f]) }
        }
        var rows: [OCRRow] = []
        for band in bands {
            var row = OCRRow()
            for f in band.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                if !row.rect.isNull && f.rect.minX - row.rect.maxX > max(0.22, row.rect.height * 8) {
                    rows.append(row)
                    row = OCRRow()
                }
                row.append(f)
            }
            rows.append(row)
        }
        return rows
    }

    private static func adjacentValue(below row: OCRRow, rows: [OCRRow], label: CGRect) -> Int? {
        rows.firstIndex { next in
            let gap = next.rect.minY - row.rect.maxY
            guard next.rect.midY > row.rect.midY, gap >= -row.rect.height * 0.2, gap < row.rect.height * 1.8,
                  abs(next.rect.minX - label.minX) < max(0.09, label.height * 4) else { return false }
            return !numberLabels.contains { $0.1.firstMatch(in: next.text, range: NSRange(location: 0, length: next.text.utf16.count)) != nil }
        }
    }

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        let value = text.substring(with: range).trimmingCharacters(in: trim)
        guard !value.isEmpty else { return NSRange(location: range.location, length: 0) }
        return text.range(of: value, options: .literal, range: range)
    }

    private static func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    // An OCR substitution such as O for 0 can break validation. Keep a complete
    // number-shaped token separate from the following form cell even in that case.
    private static func damagedNumber(in value: NSRange, text: String, kind: Redaction.Kind, inline: Bool) -> NSRange? {
        let ns = text as NSString
        guard let token = numberToken.firstMatch(in: text, options: .anchored, range: value),
              ns.substring(with: token.range).filter(\.isNumber).count >= 3 else {
            // A blank field can sit above an unrelated row containing a year.
            return inline ? value : nil
        }
        let reading = ns.substring(with: token.range)
        let length = reading.filter { $0.isLetter || $0.isNumber }.count
        let hasExpectedLength = kind == .identity ? length == 18 : [11, 13, 15].contains(length)
        return hasExpectedLength ? token.range : value
    }

    private static func idCharacters(_ value: String) -> [Character] {
        value.precomposedStringWithCompatibilityMapping.uppercased().filter { $0.isNumber || $0 == "X" }.map { $0 }
    }

    private static func hasBirthDate(_ value: String) -> Bool {
        let chars = idCharacters(value)
        guard chars.count == 18, let year = Int(String(chars[6..<10])), let month = Int(String(chars[10..<12])),
              let day = Int(String(chars[12..<14])) else { return false }
        return (1800...2099).contains(year) && (1...12).contains(month) && (1...31).contains(day)
    }

    private static func validID(_ value: String) -> Bool {
        let chars = idCharacters(value)
        guard chars.count == 18, hasBirthDate(value) else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        var sum = 0
        for (char, weight) in zip(chars, weights) {
            guard let n = char.wholeNumberValue else { return false }
            sum += n * weight
        }
        return chars.last == Array("10X98765432")[sum % 11]
    }
}
