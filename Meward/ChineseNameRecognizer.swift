import Foundation
import NaturalLanguage

struct ChineseNameRecognizer {
    private let model: NLModel
    private static let minimumMeanTagProbability = 0.55

    init() throws {
        guard let url = Bundle.main.url(forResource: "ChinesePersonName", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        model = try NLModel(contentsOf: url)
    }

    func ranges(in text: String) -> [NSRange] {
        guard text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return [] }
        // NLModel drops whitespace tokens. Keep one token per grapheme, including emoji in chat.
        let tokens = text.map { character -> String in
            if let scalar = character.unicodeScalars.first, scalar.properties.isIdeographic { return String(scalar) }
            return character.isLetter || character.isNumber || character.isPunctuation ? String(character) : "|"
        }
        let labels = model.predictedLabels(forTokens: tokens)
        guard labels.count == tokens.count else { return [] }
        let positions = Array(text.indices) + [text.endIndex]
        func isHan(_ index: Int) -> Bool { tokens[index].unicodeScalars.first?.properties.isIdeographic == true }

        var spans: [Range<Int>] = []
        var index = 0
        while index < labels.count {
            guard labels[index] == "B", isHan(index) else { index += 1; continue }
            let start = index
            index += 1
            while index < labels.count, labels[index] == "I",
                  isHan(index) || ["·", "・", "‧"].contains(tokens[index]) { index += 1 }
            guard index < labels.count, labels[index] == "E", isHan(index) else { continue }
            index += 1
            spans.append(start..<index)
        }
        guard !spans.isEmpty else { return [] }
        // OCR rows often end without punctuation. Supply a sentence boundary when scoring
        // the spans already predicted from the original text.
        let scoringTokens = isHan(tokens.count - 1) ? tokens + ["。"] : tokens
        let scores = model.predictedLabelHypotheses(forTokens: scoringTokens, maximumCount: 4)
        return spans.compactMap { span in
            if scores.count == scoringTokens.count {
                let probability = span.reduce(0.0) { $0 + (scores[$1][labels[$1]] ?? 0) } / Double(span.count)
                guard probability >= Self.minimumMeanTagProbability else { return nil }
            }
            return NSRange(positions[span.lowerBound]..<positions[span.upperBound], in: text)
        }
    }
}
