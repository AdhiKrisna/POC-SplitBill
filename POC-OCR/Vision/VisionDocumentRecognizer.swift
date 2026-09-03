import ImageIO
import UIKit
import Vision

final class VisionDocumentRecognizer {
    func recognizeText(in image: UIImage) async throws -> [VisionTextObservation] {
        guard let cgImage = image.cgImage else { throw ReceiptExtractionError.noTextFound }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { observation -> VisionTextObservation? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return VisionTextObservation(
                            text: candidate.string,
                            boundingBox: observation.boundingBox,
                            confidence: candidate.confidence,
                            words: Self.wordObservations(from: candidate)
                        )
                    }
                    .sorted { lhs, rhs in
                        abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.015
                            ? lhs.boundingBox.maxY > rhs.boundingBox.maxY
                            : lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                continuation.resume(returning: observations)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            do {
                try VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation), options: [:]).perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    private static func wordObservations(
        from candidate: VNRecognizedText
    ) -> [VisionWordObservation] {
        let text = candidate.string
        guard let expression = try? NSRegularExpression(pattern: #"\S+"#) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard let substringRange = Range(match.range, in: text),
                  let rectangle = try? candidate.boundingBox(for: substringRange) else {
                return nil
            }
            return VisionWordObservation(
                text: String(text[substringRange]),
                boundingBox: rectangle.boundingBox,
                confidence: candidate.confidence
            )
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
