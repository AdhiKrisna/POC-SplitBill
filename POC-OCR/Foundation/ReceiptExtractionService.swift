import Foundation

/// Semantic parsing only. OCR geometry remains owned by Vision.
final class FoundationReceiptExtractionService {
    private let adapter: FoundationModelAdapter

    init(adapter: FoundationModelAdapter = AppleFoundationModelAdapter()) { self.adapter = adapter }

    func extract(text: String) async throws -> SemanticReceiptExtraction {
        try await adapter.extractItems(from: text)
    }
}
