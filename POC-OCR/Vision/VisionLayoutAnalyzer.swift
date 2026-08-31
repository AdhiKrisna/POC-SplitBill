import UIKit

final class VisionLayoutAnalyzer {
    private let recognizer = VisionDocumentRecognizer()

    /// This is deliberately a separate full-document pass. Its geometry is the
    /// input to ROI discovery; it is not the OCR result passed to the semantic model.
    func analyze(image: UIImage) async throws -> VisionDocumentLayout {
        let observations = try await recognizer.recognizeText(in: image)
        return VisionDocumentLayout(observations: observations, tables: [])
    }
}
