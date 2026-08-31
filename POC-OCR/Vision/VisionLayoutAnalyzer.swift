import UIKit
import Vision

final class VisionLayoutAnalyzer {
    private let recognizer = VisionDocumentRecognizer()

    /// This is deliberately a separate full-document pass. Its geometry is the
    /// input to ROI discovery; it is not the OCR result passed to the semantic model.
    func analyze(image: UIImage) async throws -> VisionDocumentLayout {
        let observations = try await recognizer.recognizeText(in: image)
        // Structural table analysis is additive. OCR remains usable when the
        // document-structure request fails for a particular receipt.
        let tables = (try? await recognizeTableRegions(in: image)) ?? []
        return VisionDocumentLayout(observations: observations, tables: tables)
    }

    private func recognizeTableRegions(in image: UIImage) async throws -> [CGRect] {
        guard let data = image.jpegData(compressionQuality: 1) else { return [] }
        let request = RecognizeDocumentsRequest()
        let documents = try await request.perform(on: data)
        return documents.flatMap(\.document.tables).map { $0.boundingRegion.boundingBox.cgRect }
    }
}
