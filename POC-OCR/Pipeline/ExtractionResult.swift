import Foundation
import UIKit

struct ExtractionResult: Identifiable {
    let id = UUID()
    let summary: ReceiptSummary
    let diagnostics: ExtractionDiagnostics
    let preprocessedImage: UIImage?
    /// Native parser input. This can be an ROI crop and is not the default
    /// LayoutLMv3 export input.
    let ocrImage: UIImage
    let ocrObservations: [VisionTextObservation]

    /// Full preprocessed document and the Vision boxes produced in that exact
    /// coordinate space. P0 exports only this pair.
    let layoutLMv3Image: UIImage
    let layoutLMv3Observations: [VisionTextObservation]
    let layoutLMv3DocumentScope: VisionOCRDocumentScope
    let layoutLMv3TransactionROIRect: CGRect?
}
