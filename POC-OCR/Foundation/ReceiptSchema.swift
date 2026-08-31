import Foundation

struct SemanticReceiptItem: Sendable, Hashable {
    var name: String
    var quantity: Double?
    var unitPrice: Double?
    var totalPrice: Double?
}

struct SemanticReceiptExtraction: Sendable {
    var items: [SemanticReceiptItem]
}
