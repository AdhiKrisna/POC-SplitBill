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

final class ReceiptExtractionPipeline {
    private let layoutAnalyzer = VisionLayoutAnalyzer()
    private let roiResolver = VisionROIResolver()
    private let ocr = VisionDocumentRecognizer()
    private let parser = LegacyReceiptParser()
    private let foundation = FoundationReceiptExtractionService()

    func extract(image: UIImage, mode: ExtractionMode) async throws -> ExtractionResult {
        let layout = try await layoutAnalyzer.analyze(image: image)
        guard !layout.observations.isEmpty else { throw ReceiptExtractionError.noTextFound }
        let resolution = roiResolver.resolve(layout: layout)
        let useROI = mode.usesROI && !resolution.usedFallback && resolution.confidence.isReliable
        let recognitionImage = useROI ? image.cropped(normalizedVisionRect: resolution.rect!) : image
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

        let fallback = mode.usesROI && !useROI ? "full_document" : nil
        let diagnostics = ExtractionDiagnostics(
            requestedROI: mode.usesROI,
            roiRect: resolution.rect,
            roiConfidence: resolution.confidence,
            roiUsed: useROI,
            fallback: fallback,
            layoutObservationCount: layout.observations.count,
            ocrObservationCount: ocrObservations.count,
            foundationInput: text,
            foundationOutput: foundationOutput
        )
        return ExtractionResult(summary: ReceiptSummary(items: items, rawText: text), diagnostics: diagnostics)
    }
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
