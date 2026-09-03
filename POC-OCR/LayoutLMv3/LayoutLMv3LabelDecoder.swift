@preconcurrency import CoreML
import Foundation

enum LayoutLMv3LabelError: LocalizedError {
    case missingLabels
    case invalidLabels
    case invalidLogitsShape([Int])
    case unknownLabelID(Int)

    var errorDescription: String? {
        switch self {
        case .missingLabels:
            return "labels.json is missing from the app target."
        case .invalidLabels:
            return "labels.json does not contain a valid id2label mapping."
        case .invalidLogitsShape(let shape):
            return "Core ML logits shape is invalid: \(shape)."
        case .unknownLabelID(let id):
            return "Core ML returned unknown label ID \(id)."
        }
    }
}

struct LayoutLMv3LabelDecoder {
    private let labels: [Int: String]

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw LayoutLMv3LabelError.missingLabels
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawLabels = root["id2label"] as? [String: Any] else {
            throw LayoutLMv3LabelError.invalidLabels
        }
        var labels: [Int: String] = [:]
        for (rawID, rawLabel) in rawLabels {
            guard let id = Int(rawID), let label = rawLabel as? String else {
                throw LayoutLMv3LabelError.invalidLabels
            }
            labels[id] = label
        }
        guard !labels.isEmpty,
              Set(labels.keys) == Set(0..<labels.count) else {
            throw LayoutLMv3LabelError.invalidLabels
        }
        self.labels = labels
    }

    func decode(logits: MLMultiArray, tokens: [LayoutToken]) throws -> [TokenPrediction] {
        let shape = logits.shape.map(\.intValue)
        guard shape.count == 3,
              shape[0] == 1,
              shape[1] == LayoutLMv3InputBuilder.sequenceLength,
              shape[2] == labels.count,
              tokens.count == shape[1] else {
            throw LayoutLMv3LabelError.invalidLogitsShape(shape)
        }

        return try tokens.enumerated().compactMap { index, token in
            guard token.wordIndex != nil else { return nil }
            var bestID = 0
            var bestLogit = -Double.infinity
            var denominator = 0.0
            var values = [Double](repeating: 0, count: labels.count)
            for labelID in 0..<labels.count {
                // Core ML may pad the last logits dimension (for example, 9
                // labels stored with a stride of 32). Use logical coordinates
                // instead of passing a computed storage offset to the linear
                // subscript, which can read beyond MLMultiArray.count.
                let value = logits[
                    [
                        NSNumber(value: 0),
                        NSNumber(value: index),
                        NSNumber(value: labelID),
                    ]
                ].doubleValue
                values[labelID] = value
                if value > bestLogit {
                    bestLogit = value
                    bestID = labelID
                }
            }
            guard let label = labels[bestID] else {
                throw LayoutLMv3LabelError.unknownLabelID(bestID)
            }
            for value in values { denominator += exp(value - bestLogit) }
            let confidence = Float(1.0 / denominator)
            return TokenPrediction(
                tokenIndex: index,
                token: token.token,
                wordIndex: token.wordIndex,
                labelID: bestID,
                label: label,
                confidence: confidence
            )
        }
    }
}
