@preconcurrency import CoreML
import CoreGraphics
import UIKit

struct LayoutLMv3PreparedInput {
    let words: [OCRWord]
    let tokens: [LayoutToken]
    let inputIDs: MLMultiArray
    let attentionMask: MLMultiArray
    let bbox: MLMultiArray
    let pixelValues: MLMultiArray
}

enum LayoutLMv3InputError: LocalizedError {
    case noWords
    case shapeMismatch(String)
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .noWords:
            return "Vision OCR returned no words for LayoutLMv3."
        case .shapeMismatch(let reason):
            return "LayoutLMv3 input shape mismatch: \(reason)"
        case .imageConversionFailed:
            return "Could not convert the receipt image to the 224 x 224 RGB tensor."
        }
    }
}

struct LayoutLMv3InputBuilder {
    static let sequenceLength = 512
    static let imageSize = 224

    func words(from observations: [VisionTextObservation]) throws -> [OCRWord] {
        // A line-level fallback corrupts LayoutLMv3's word-to-box alignment.
        // If Vision cannot provide range boxes, fail clearly instead of
        // pretending one VNRecognizedTextObservation is one word.
        let words = observations.flatMap(\.words)
            .map(Self.makeOCRWord)
        .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sortedWords = Self.sortReadingOrder(words)
        guard !sortedWords.isEmpty else { throw LayoutLMv3InputError.noWords }
        return sortedWords
    }

    func build(image: UIImage, words: [OCRWord], tokenizer: LayoutLMv3Tokenizer) throws -> LayoutLMv3PreparedInput {
        guard !words.isEmpty else { throw LayoutLMv3InputError.noWords }
        var tokens = [LayoutToken(
            token: "<s>", tokenId: tokenizer.clsTokenID, wordIndex: nil,
            bbox: tokenizer.clsTokenBox
        )]
        let contentLimit = Self.sequenceLength - 1
        for (wordIndex, word) in words.enumerated() {
            let box = Self.layoutBox(word.boundingBox)
            let subwords = try tokenizer.tokenize(word: word.text)
            for subword in subwords {
                guard tokens.count < contentLimit else { break }
                tokens.append(LayoutToken(
                    token: subword.token,
                    tokenId: subword.id,
                    wordIndex: wordIndex,
                    bbox: box
                ))
            }
            if tokens.count >= contentLimit { break }
        }
        tokens.append(LayoutToken(
            token: "</s>", tokenId: tokenizer.sepTokenID, wordIndex: nil,
            bbox: tokenizer.sepTokenBox
        ))
        let attendedCount = tokens.count
        while tokens.count < Self.sequenceLength {
            tokens.append(LayoutToken(
                token: "<pad>", tokenId: tokenizer.padTokenID, wordIndex: nil,
                bbox: tokenizer.padTokenBox
            ))
        }
        guard tokens.count == Self.sequenceLength else {
            throw LayoutLMv3InputError.shapeMismatch("token count is \(tokens.count), expected 512")
        }

        let inputIDs = try MLMultiArray(shape: [1, 512], dataType: .int32)
        let attentionMask = try MLMultiArray(shape: [1, 512], dataType: .int32)
        let bbox = try MLMultiArray(shape: [1, 512, 4], dataType: .int32)
        for index in 0..<Self.sequenceLength {
            inputIDs[index] = NSNumber(value: Int32(tokens[index].tokenId))
            attentionMask[index] = NSNumber(value: Int32(index < attendedCount ? 1 : 0))
            for coordinate in 0..<4 {
                bbox[index * 4 + coordinate] = NSNumber(value: Int32(tokens[index].bbox[coordinate]))
            }
        }

        return LayoutLMv3PreparedInput(
            words: words,
            tokens: tokens,
            inputIDs: inputIDs,
            attentionMask: attentionMask,
            bbox: bbox,
            pixelValues: try makePixelValues(image)
        )
    }

    private func makePixelValues(_ image: UIImage) throws -> MLMultiArray {
        guard let cgImage = uprightCGImage(image) else {
            throw LayoutLMv3InputError.imageConversionFailed
        }
        let size = Self.imageSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw LayoutLMv3InputError.imageConversionFailed }
        // CGContext preserves CGImage scanline order in this RGBA bitmap.
        // A UIKit-style vertical flip here would invert the model tensor.
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let result = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32)
        let plane = size * size
        for y in 0..<size {
            for x in 0..<size {
                let source = (y * size + x) * 4
                let destination = y * size + x
                for channel in 0..<3 {
                    // Default LayoutLMv3 image mean/std are both 0.5.
                    let normalized = (Float(pixels[source + channel]) / 255.0 - 0.5) / 0.5
                    result[channel * plane + destination] = NSNumber(value: normalized)
                }
            }
        }
        return result
    }

    private func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up {
            return image.cgImage
        }
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }.cgImage
    }

    nonisolated private static func makeOCRWord(_ word: VisionWordObservation) -> OCRWord {
        let box = word.boundingBox
        return OCRWord(
            text: word.text,
            boundingBox: CGRect(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            ),
            confidence: word.confidence
        )
    }

    /// Isolated because receipt reading order will likely need its own model.
    /// The current prototype groups nearby y-centers into rows, then sorts x.
    nonisolated private static func sortReadingOrder(_ words: [OCRWord]) -> [OCRWord] {
        guard !words.isEmpty else { return [] }
        let meanHeight = words.map(\.boundingBox.height).reduce(0, +) / CGFloat(words.count)
        let tolerance = max(0.008, meanHeight * 0.6)
        let ordered = words.sorted {
            $0.boundingBox.midY == $1.boundingBox.midY
                ? $0.boundingBox.minX < $1.boundingBox.minX
                : $0.boundingBox.midY < $1.boundingBox.midY
        }
        var rows: [[OCRWord]] = []
        for word in ordered {
            guard let lastRow = rows.last else {
                rows.append([word])
                continue
            }
            let rowCenter = lastRow.map(\.boundingBox.midY).reduce(0, +) / CGFloat(lastRow.count)
            if abs(word.boundingBox.midY - rowCenter) <= tolerance {
                rows[rows.count - 1].append(word)
            } else {
                rows.append([word])
            }
        }
        return rows.flatMap { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }
    }

    nonisolated static func layoutBox(_ rect: CGRect) -> [Int] {
        let x0 = clamp(Int((rect.minX * 1000).rounded()))
        let y0 = clamp(Int((rect.minY * 1000).rounded()))
        let x1 = max(x0, clamp(Int((rect.maxX * 1000).rounded())))
        let y1 = max(y0, clamp(Int((rect.maxY * 1000).rounded())))
        assert(x0 <= x1 && y0 <= y1)
        return [x0, y0, x1, y1]
    }

    nonisolated private static func clamp(_ value: Int) -> Int {
        min(1000, max(0, value))
    }
}
