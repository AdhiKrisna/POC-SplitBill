import Foundation
import UIKit

struct ExtractionResult: Identifiable {
    let id = UUID()
    let summary: ReceiptSummary
    let diagnostics: ExtractionDiagnostics
    let preprocessedImage: UIImage?
}
