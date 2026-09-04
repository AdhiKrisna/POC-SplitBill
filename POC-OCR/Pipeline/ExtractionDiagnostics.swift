import CoreGraphics
import Foundation

struct ExtractionDiagnostics: Sendable {
    let extractionMode: ExtractionMode
    let documentDetected: Bool
    let documentConfidence: Double
    let documentQuadrilateral: DocumentQuadrilateral?
    let documentFallback: String?
    let rectifiedImageSize: CGSize?
    let requestedROI: Bool
    let roiRect: CGRect?
    let roiConfidence: ROIConfidence
    let roiUsed: Bool
    let roiFallback: String?
    let roiStrategy: ROIStrategy
    let transactionRowCount: Int
    let structuredTransactionText: String?
    let layoutObservationCount: Int
    let ocrObservationCount: Int
    let foundationInput: String
    let foundationOutput: String
    let fastVLMOutput: String
}
