@preconcurrency import CoreML
import Foundation

struct LayoutLMv3DebugRect: Codable, Sendable {
    let x0: Double
    let y0: Double
    let x1: Double
    let y1: Double
}

struct LayoutLMv3DebugWord: Codable, Sendable {
    let index: Int
    let text: String
    let confidence: Float
    /// Original Vision coordinates, normalized with a bottom-left origin.
    let visionBBox: LayoutLMv3DebugRect
    /// LayoutLM coordinates, integer top-left origin in 0...1000.
    let normalizedBBox: [Int]
}

struct LayoutLMv3DebugToken: Codable, Sendable {
    let index: Int
    let token: String
    let tokenID: Int
    let wordIndex: Int?
    let bbox: [Int]
    let attentionMask: Int
    let predictedLabelID: Int?
    let predictedLabel: String?
    let confidence: Float?
}

struct LayoutLMv3PixelDebug: Codable, Sendable {
    let shape: [Int]
    let colorSpace: String
    let resize: String
    let normalization: String
    let minimum: Float
    let maximum: Float
    let mean: Float
    /// Contiguous NCHW Float32 values. iOS devices are little-endian.
    let float32LittleEndianBase64: String
}

struct LayoutLMv3LogitsDebug: Codable, Sendable {
    let shape: [Int]
    let float32LittleEndianBase64: String
}

struct LayoutLMv3DebugExport: Codable, Sendable {
    let schemaVersion: Int
    let coordinateConvention: String
    let words: [LayoutLMv3DebugWord]
    let tokens: [LayoutLMv3DebugToken]
    let inputIDs: [Int]
    let attentionMask: [Int]
    let bbox: [[Int]]
    let wordIDs: [Int?]
    let labelIDs: [Int?]
    let pixelValues: LayoutLMv3PixelDebug
    let logits: LayoutLMv3LogitsDebug
    let reconstruction: LayoutLMv3ReconstructionTrace

    static func make(
        prepared: LayoutLMv3PreparedInput,
        predictions: [TokenPrediction],
        logits: MLMultiArray,
        reconstruction: LayoutLMv3ReconstructionTrace
    ) -> LayoutLMv3DebugExport {
        let predictionByToken = Dictionary(uniqueKeysWithValues: predictions.map {
            ($0.tokenIndex, $0)
        })
        let attentionMask = (0..<prepared.tokens.count).map {
            prepared.attentionMask[[NSNumber(value: 0), NSNumber(value: $0)]].intValue
        }
        let words = prepared.words.enumerated().map { index, word in
            let topLeft = word.boundingBox
            return LayoutLMv3DebugWord(
                index: index,
                text: word.text,
                confidence: word.confidence,
                visionBBox: LayoutLMv3DebugRect(
                    x0: topLeft.minX,
                    y0: 1 - topLeft.maxY,
                    x1: topLeft.maxX,
                    y1: 1 - topLeft.minY
                ),
                normalizedBBox: LayoutLMv3InputBuilder.layoutBox(topLeft)
            )
        }
        let tokens = prepared.tokens.enumerated().map { index, token in
            let prediction = predictionByToken[index]
            return LayoutLMv3DebugToken(
                index: index,
                token: token.token,
                tokenID: token.tokenId,
                wordIndex: token.wordIndex,
                bbox: token.bbox,
                attentionMask: attentionMask[index],
                predictedLabelID: prediction?.labelID,
                predictedLabel: prediction?.label,
                confidence: prediction?.confidence
            )
        }
        return LayoutLMv3DebugExport(
            schemaVersion: 2,
            coordinateConvention: "Vision bottom-left normalized; LayoutLM top-left integer 0...1000",
            words: words,
            tokens: tokens,
            inputIDs: prepared.tokens.map(\.tokenId),
            attentionMask: attentionMask,
            bbox: prepared.tokens.map(\.bbox),
            wordIDs: prepared.tokens.map(\.wordIndex),
            labelIDs: tokens.map(\.predictedLabelID),
            pixelValues: pixelDebug(prepared.pixelValues),
            logits: logitsDebug(logits),
            reconstruction: reconstruction
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }

    private static func pixelDebug(_ values: MLMultiArray) -> LayoutLMv3PixelDebug {
        let count = values.count
        let pointer = values.dataPointer.bindMemory(to: Float.self, capacity: count)
        var minimum = Float.infinity
        var maximum = -Float.infinity
        var total: Double = 0
        for index in 0..<count {
            let value = pointer[index]
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            total += Double(value)
        }
        let bytes = Data(bytes: pointer, count: count * MemoryLayout<Float>.size)
        return LayoutLMv3PixelDebug(
            shape: values.shape.map(\.intValue),
            colorSpace: "RGB",
            resize: "224x224 bilinear-compatible stretch",
            normalization: "value = (uint8 / 255 - 0.5) / 0.5",
            minimum: minimum,
            maximum: maximum,
            mean: Float(total / Double(max(count, 1))),
            float32LittleEndianBase64: bytes.base64EncodedString()
        )
    }

    private static func logitsDebug(_ logits: MLMultiArray) -> LayoutLMv3LogitsDebug {
        let shape = logits.shape.map(\.intValue)
        guard shape.count == 3 else {
            return LayoutLMv3LogitsDebug(shape: shape, float32LittleEndianBase64: "")
        }
        var values = [Float]()
        values.reserveCapacity(shape.reduce(1, *))
        for batch in 0..<shape[0] {
            for token in 0..<shape[1] {
                for label in 0..<shape[2] {
                    values.append(logits[
                        [NSNumber(value: batch), NSNumber(value: token), NSNumber(value: label)]
                    ].floatValue)
                }
            }
        }
        return values.withUnsafeBytes { bytes in
            LayoutLMv3LogitsDebug(
                shape: shape,
                float32LittleEndianBase64: Data(bytes).base64EncodedString()
            )
        }
    }
}
