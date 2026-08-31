import Foundation

enum FoundationModelAdapterError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Foundation Models tidak tersedia di perangkat ini." }
}

protocol FoundationModelAdapter {
    func extractItems(from text: String) async throws -> SemanticReceiptExtraction
}

// Enable this condition in the app target when building with the Apple SDK that
// ships the FoundationModels macro plug-in. Keeping it explicit lets the POC
// run its comparable Vision + Regex baselines on SDK installations without it.
#if FOUNDATION_MODELS_ENABLED && canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
private struct GeneratedReceiptItem {
    var name: String
    var quantity: Double?
    var unitPrice: Double?
    var totalPrice: Double?
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedReceiptExtraction {
    var items: [GeneratedReceiptItem]
}

final class AppleFoundationModelAdapter: FoundationModelAdapter {
    func extractItems(from text: String) async throws -> SemanticReceiptExtraction {
        guard #available(iOS 26.0, *) else { throw FoundationModelAdapterError.unavailable }
        guard case .available = SystemLanguageModel.default.availability else { throw FoundationModelAdapterError.unavailable }
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: """
            Extract purchased receipt items only. Do not include subtotal, tax, totals, payments, or change.
            Preserve item names. Convert Indonesian number formatting to plain numeric values.
            OCR ITEM REGION:\n\(text)
            """,
            generating: GeneratedReceiptExtraction.self
        )
        return SemanticReceiptExtraction(items: response.content.items.map {
            SemanticReceiptItem(name: $0.name, quantity: $0.quantity, unitPrice: $0.unitPrice, totalPrice: $0.totalPrice)
        })
    }
}
#else
final class AppleFoundationModelAdapter: FoundationModelAdapter {
    func extractItems(from text: String) async throws -> SemanticReceiptExtraction { throw FoundationModelAdapterError.unavailable }
}
#endif
