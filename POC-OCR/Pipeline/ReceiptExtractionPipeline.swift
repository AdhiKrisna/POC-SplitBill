import UIKit

enum ExtractionMode: String, CaseIterable, Identifiable {
    case fullReceiptRegex = "Rectified + Regex"
    case roiRegex = "ROI + Rectified + Regex"
    case fullReceiptFoundation = "Rectified + Foundation"
    case roiFoundation = "ROI + Rectified + Foundation"
    case layoutLMv3 = "LayoutLMv3 Export"
    case visionLayoutLMv3 = "Vision + LayoutLMv3 Local"

    var id: String { rawValue }
    var usesROI: Bool {
        self == .roiRegex || self == .roiFoundation
    }
    var usesFoundation: Bool {
        self == .fullReceiptFoundation || self == .roiFoundation
    }
    var usesLayoutLMv3: Bool {
        self == .layoutLMv3 || self == .visionLayoutLMv3
    }
}

final class ReceiptExtractionPipeline {
    private let layoutAnalyzer = VisionLayoutAnalyzer()
    private let roiResolver = VisionROIResolver()
    private let ocr = VisionDocumentRecognizer()
    private let parser = LegacyReceiptParser()
    private let foundation = FoundationReceiptExtractionService()
    private let documentSegmentation = VisionDocumentSegmentation()
    private let documentRectifier = DocumentRectifier()
    private let layoutLMv3Extractor = LayoutLMv3ReceiptExtractor()

    func extract(
        image: UIImage,
        mode: ExtractionMode
    ) async throws -> ExtractionResult {
        let isLayoutLMv3 = mode.usesLayoutLMv3
        let runsLocalLayoutLMv3 = mode == .visionLayoutLMv3
        let preprocessed = await preprocess(
            image: image
        )

        // This is the LayoutLMv3 OCR contract: the complete preprocessed
        // document and observations in that image's coordinate system.
        // It deliberately runs before, and independently from, legacy ROI work.
        let fullDocumentObservations = try await ocr.recognizeText(
            in: preprocessed.image
        )

        guard !fullDocumentObservations.isEmpty else {
            throw ReceiptExtractionError.noTextFound
        }

        let layoutLMDocument = RectifiedReceiptDocument(
            image: preprocessed.image,
            quadrilateral: preprocessed.segmentation.quadrilateral,
            observations: fullDocumentObservations
        )

        // RecognizeDocumentsRequest and ROIDetector remain available only to
        // legacy ROI experiments. They are not part of LayoutLMv3 preparation.
        let resolution: ROIResolution
        if mode.usesROI && !isLayoutLMv3 {
            let legacyLayout = await layoutAnalyzer.analyzeLegacyROI(
                image: preprocessed.image,
                observations: fullDocumentObservations
            )
            resolution = roiResolver.resolve(layout: legacyLayout)
        } else {
            resolution = notRequestedROI()
        }

        let useROI =
            !isLayoutLMv3
            && mode.usesROI
            && !resolution.usedFallback
            && resolution.confidence.isReliable
            && resolution.rect != nil

        // Keep the existing second OCR pass for Regex and as the fallback
        // source of truth. The new structured table text is used only by the
        // Foundation path so this experiment isolates the effect of structure.
        let recognitionImage = !isLayoutLMv3 && useROI
            ? preprocessed.image.cropped(
                normalizedVisionRect: resolution.rect!
            )
            : preprocessed.image

        let ocrObservations = !isLayoutLMv3 && useROI
            ? try await ocr.recognizeText(in: recognitionImage)
            : fullDocumentObservations

        let ocrText = ocrObservations
            .map(\.text)
            .joined(separator: "\n")

        // Foundation receives structured transaction rows when the new
        // RecognizeDocumentsRequest resolver succeeded. Otherwise it keeps
        // the previous OCR text path.
        let foundationInput: String
        if mode.usesFoundation,
           mode.usesROI,
           let structuredText = resolution.structuredText,
           !structuredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            foundationInput = structuredText
        } else {
            foundationInput = ocrText
        }

        var foundationOutput = "Not requested"
        var layoutLMv3Predictions: [TokenPrediction] = []
        var layoutLMv3DebugExport: LayoutLMv3DebugExport?
        let items: [ReceiptItem]

        if mode.usesFoundation {
            do {
                let semantic = try await foundation.extract(
                    text: foundationInput
                )

                foundationOutput = semantic.items.map { item in
                    "\(item.name) | qty=\(debugNumber(item.quantity)) | unit=\(debugNumber(item.unitPrice)) | total=\(debugNumber(item.totalPrice))"
                }
                .joined(separator: "\n")

                items = semantic.items.map { semanticItem in
                    let quantity = max(
                        Int((semanticItem.quantity ?? 1).rounded()),
                        1
                    )

                    let unitPrice =
                        semanticItem.unitPrice
                        ?? (semanticItem.totalPrice ?? 0) / Double(quantity)

                    return ReceiptItem(
                        name: semanticItem.name,
                        quantity: quantity,
                        unitPrice: unitPrice,
                        discountAmount: 0
                    )
                }
            } catch {
                foundationOutput =
                    "Unavailable/failed: \(error.localizedDescription). Legacy parser used."

                items = parser.parse(ocrObservations)
            }
        } else if runsLocalLayoutLMv3 {
            let output = try await layoutLMv3Extractor.predict(
                from: layoutLMDocument.image,
                observations: layoutLMDocument.observations
            )
            items = output.items
            layoutLMv3Predictions = output.tokenPredictions
            layoutLMv3DebugExport = output.debugExport
        } else if isLayoutLMv3 {
            items = []
        } else {
            items = parser.parse(ocrObservations)
        }

        let roiFallback =
            mode.usesROI && !useROI
            ? "full_document"
            : nil

        let diagnostics = ExtractionDiagnostics(
            extractionMode: mode,
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
            roiStrategy: resolution.confidence.strategy,
            transactionRowCount: resolution.transactionRowCount,
            structuredTransactionText: resolution.structuredText,
            layoutObservationCount: fullDocumentObservations.count,
            ocrObservationCount: ocrObservations.count,
            foundationInput: foundationInput,
            foundationOutput: foundationOutput
        )

        return ExtractionResult(
            summary: ReceiptSummary(
                items: items,
                rawText: ocrText
            ),
            diagnostics: diagnostics,
            preprocessedImage: preprocessed.didTransform
                ? preprocessed.image
                : nil,
            ocrImage: recognitionImage,
            ocrObservations: ocrObservations,
            layoutLMv3Image: layoutLMDocument.image,
            layoutLMv3Observations: layoutLMDocument.observations,
            layoutLMv3DocumentScope:
                preprocessed.rectifiedImageSize != nil
                ? .fullRectifiedDocument
                : .fullDocumentUnrectified,
            layoutLMv3Predictions: layoutLMv3Predictions,
            layoutLMv3DebugExport: layoutLMv3DebugExport
        )
    }

    private func preprocess(
        image: UIImage
    ) async -> PreprocessedDocument {
        let segmentation: DocumentSegmentationResult

        do {
            segmentation = try await documentSegmentation.detectDocument(
                image: image
            )
        } catch {
            return PreprocessedDocument(
                image: image,
                segmentation: notRequestedSegmentation(
                    reason: error.localizedDescription
                ),
                fallback: "original_image",
                rectifiedImageSize: nil,
                didTransform: false
            )
        }

        guard segmentation.isReliable,
              let quadrilateral = segmentation.quadrilateral else {
            return PreprocessedDocument(
                image: image,
                segmentation: segmentation,
                fallback: "original_image",
                rectifiedImageSize: nil,
                didTransform: false
            )
        }

        do {
            let rectified = try documentRectifier.rectify(
                image: image,
                quadrilateral: quadrilateral
            )

            return PreprocessedDocument(
                image: rectified,
                segmentation: segmentation,
                fallback: nil,
                rectifiedImageSize: rectified.size,
                didTransform: true
            )
        } catch {
            return PreprocessedDocument(
                image: image,
                segmentation: segmentation,
                fallback: "original_image_after_rectification_failure",
                rectifiedImageSize: nil,
                didTransform: false
            )
        }
    }

    private func notRequestedSegmentation(
        reason: String = "Not requested"
    ) -> DocumentSegmentationResult {
        DocumentSegmentationResult(
            quadrilateral: nil,
            confidence: 0,
            detected: false,
            failureReason: reason
        )
    }

    private func notRequestedROI() -> ROIResolution {
        ROIResolution(
            rect: nil,
            confidence: ROIConfidence(
                value: 0,
                strategy: .fullDocument,
                reason: "Not requested for this extraction mode"
            ),
            usedFallback: false,
            structuredText: nil,
            transactionRowCount: 0
        )
    }
}

private struct PreprocessedDocument {
    let image: UIImage
    let segmentation: DocumentSegmentationResult
    let fallback: String?
    let rectifiedImageSize: CGSize?
    let didTransform: Bool
}

/// Full receipt image plus OCR observations in the exact same coordinate
/// system. This is the LayoutLMv3 handoff; it intentionally has no ROI field.
private struct RectifiedReceiptDocument {
    let image: UIImage
    let quadrilateral: DocumentQuadrilateral?
    let observations: [VisionTextObservation]
}

private func debugNumber(_ value: Double?) -> String {
    guard let value else { return "nil" }
    return String(value)
}

private extension UIImage {
    func cropped(normalizedVisionRect rect: CGRect) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)

        let upright = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }

        guard let cgImage = upright.cgImage else {
            return self
        }

        let pixelRect = CGRect(
            x: rect.minX * CGFloat(cgImage.width),
            y: (1 - rect.maxY) * CGFloat(cgImage.height),
            width: rect.width * CGFloat(cgImage.width),
            height: rect.height * CGFloat(cgImage.height)
        )
        .integral
        .intersection(
            CGRect(
                x: 0,
                y: 0,
                width: cgImage.width,
                height: cgImage.height
            )
        )

        guard let cropped = cgImage.cropping(to: pixelRect),
              !pixelRect.isEmpty else {
            return self
        }

        return UIImage(cgImage: cropped)
    }
}
