import CoreGraphics
import Foundation

struct ExtractionDiagnostics: Sendable {
    let requestedROI: Bool
    let roiRect: CGRect?
    let roiConfidence: ROIConfidence
    let roiUsed: Bool
    let fallback: String?
    let layoutObservationCount: Int
    let ocrObservationCount: Int
    let foundationInput: String
    let foundationOutput: String
}
