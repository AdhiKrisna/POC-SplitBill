import UIKit

enum ExtractionMode: String, CaseIterable, Identifiable {
    case fullReceiptRegex = "Vision + Regex"
    case roiRegex = "Vision + ROI + Regex"
    case fullReceiptFoundation = "Vision + Foundation"
    case roiFoundation = "Vision + ROI + Foundation"

    var id: String { rawValue }
    var usesROI: Bool { self == .roiRegex || self == .roiFoundation }
    var usesFoundation: Bool { self == .fullReceiptFoundation || self == .roiFoundation }
}

enum DocumentPreprocessingMode: String, CaseIterable, Identifiable, Sendable {
    case original = "Original image"
    case documentSegmentation = "Document Segmentation"
    case documentSegmentationAndRectification = "Segmentation + Rectification"

    var id: String { rawValue }
}

final class ReceiptExtractionPipeline {
    private let layoutAnalyzer = VisionLayoutAnalyzer()
    private let roiResolver = VisionROIResolver()
    private let ocr = VisionDocumentRecognizer()
    private let parser = LegacyReceiptParser()
    private let foundation = FoundationReceiptExtractionService()
    private let documentSegmentation = VisionDocumentSegmentation()
    private let documentRectifier = DocumentRectifier()

    func extract(image: UIImage, mode: ExtractionMode, preprocessing: DocumentPreprocessingMode) async throws -> ExtractionResult {
        let preprocessed = await preprocess(image: image, mode: preprocessing)
        let layout = try await layoutAnalyzer.analyze(image: preprocessed.image)
        guard !layout.observations.isEmpty else { throw ReceiptExtractionError.noTextFound }
        let resolution = roiResolver.resolve(layout: layout)
        let useROI = mode.usesROI && !resolution.usedFallback && resolution.confidence.isReliable
        let recognitionImage = useROI ? preprocessed.image.cropped(normalizedVisionRect: resolution.rect!) : preprocessed.image
        let ocrObservations = useROI ? try await ocr.recognizeText(in: recognitionImage) : layout.observations
        let text = ocrObservations.map(\.text).joined(separator: "\n")

        var foundationOutput = "Not requested"
        let items: [ReceiptItem]
        if mode.usesFoundation {
            do {
                let semantic = try await foundation.extract(text: text)
                foundationOutput = semantic.items.map { item in
                    "\(item.name) | qty=\(debugNumber(item.quantity)) | unit=\(debugNumber(item.unitPrice)) | total=\(debugNumber(item.totalPrice))"
                }.joined(separator: "\n")
                items = semantic.items.map { semanticItem in
                    let quantity = max(Int((semanticItem.quantity ?? 1).rounded()), 1)
                    let unitPrice = semanticItem.unitPrice ?? (semanticItem.totalPrice ?? 0) / Double(quantity)
                    return ReceiptItem(name: semanticItem.name, quantity: quantity, unitPrice: unitPrice, discountAmount: 0)
                }
            } catch {
                foundationOutput = "Unavailable/failed: \(error.localizedDescription). Legacy parser used."
                items = parser.parse(ocrObservations)
            }
        } else {
            items = parser.parse(ocrObservations)
        }

        let roiFallback = mode.usesROI && !useROI ? "full_document" : nil
        let diagnostics = ExtractionDiagnostics(
            extractionMode: mode,
            preprocessingMode: preprocessing,
            documentDetected: preprocessed.segmentation.detected,
            documentConfidence: preprocessed.segmentation.confidence,
            documentQuadrilateral: preprocessed.segmentation.quadrilateral,
            documentFallback: preprocessed.fallback,
            rectifiedImageSize: preprocessed.rectifiedImageSize,
            requestedROI: mode.usesROI,
            roiRect: resolution.rect,
            roiConfidence: resolution.confidence,
            roiUsed: useROI,
            roiFallback: roiFallback,
            layoutObservationCount: layout.observations.count,
            ocrObservationCount: ocrObservations.count,
            foundationInput: text,
            foundationOutput: foundationOutput
        )
        return ExtractionResult(
            summary: ReceiptSummary(items: items, rawText: text),
            diagnostics: diagnostics,
            preprocessedImage: preprocessed.didTransform ? preprocessed.image : nil
        )
    }

    private func preprocess(image: UIImage, mode: DocumentPreprocessingMode) async -> PreprocessedDocument {
        guard mode != .original else {
            return PreprocessedDocument(image: image, segmentation: notRequestedSegmentation(), fallback: nil, rectifiedImageSize: nil, didTransform: false)
        }

        let segmentation: DocumentSegmentationResult
        do {
            segmentation = try await documentSegmentation.detectDocument(image: image)
        } catch {
            return PreprocessedDocument(image: image, segmentation: notRequestedSegmentation(reason: error.localizedDescription), fallback: "original_image", rectifiedImageSize: nil, didTransform: false)
        }
        guard segmentation.isReliable, let quadrilateral = segmentation.quadrilateral else {
            return PreprocessedDocument(image: image, segmentation: segmentation, fallback: "original_image", rectifiedImageSize: nil, didTransform: false)
        }

        switch mode {
        case .original:
            return PreprocessedDocument(image: image, segmentation: segmentation, fallback: nil, rectifiedImageSize: nil, didTransform: false)
        case .documentSegmentation:
            // This mode localizes the physical document but intentionally keeps
            // its original perspective. Rectification is a separate variable.
            let crop = quadrilateral.boundingRect
                .insetBy(dx: -0.02, dy: -0.02)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return PreprocessedDocument(image: image.cropped(normalizedVisionRect: crop), segmentation: segmentation, fallback: nil, rectifiedImageSize: nil, didTransform: true)
        case .documentSegmentationAndRectification:
            do {
                let rectified = try documentRectifier.rectify(image: image, quadrilateral: quadrilateral)
                return PreprocessedDocument(image: rectified, segmentation: segmentation, fallback: nil, rectifiedImageSize: rectified.size, didTransform: true)
            } catch {
                // Segmentation is non-fatal. Preserve original geometry when its
                // perspective transform cannot be rendered.
                return PreprocessedDocument(image: image, segmentation: segmentation, fallback: "original_image_after_rectification_failure", rectifiedImageSize: nil, didTransform: false)
            }
        }
    }

    private func notRequestedSegmentation(reason: String = "Not requested") -> DocumentSegmentationResult {
        DocumentSegmentationResult(quadrilateral: nil, confidence: 0, detected: false, failureReason: reason)
    }
}

private struct PreprocessedDocument {
    let image: UIImage
    let segmentation: DocumentSegmentationResult
    let fallback: String?
    let rectifiedImageSize: CGSize?
    let didTransform: Bool
}

private func debugNumber(_ value: Double?) -> String {
    guard let value else { return "nil" }
    return String(value)
}

private extension UIImage {
    func cropped(normalizedVisionRect rect: CGRect) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let upright = renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        guard let cgImage = upright.cgImage else { return self }
        let pixelRect = CGRect(
            x: rect.minX * CGFloat(cgImage.width),
            y: (1 - rect.maxY) * CGFloat(cgImage.height),
            width: rect.width * CGFloat(cgImage.width),
            height: rect.height * CGFloat(cgImage.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let cropped = cgImage.cropping(to: pixelRect), !pixelRect.isEmpty else { return self }
        return UIImage(cgImage: cropped)
    }
}
