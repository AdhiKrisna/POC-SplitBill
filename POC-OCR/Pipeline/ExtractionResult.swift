import Foundation

struct ExtractionResult: Identifiable {
    let id = UUID()
    let summary: ReceiptSummary
    let diagnostics: ExtractionDiagnostics
}
