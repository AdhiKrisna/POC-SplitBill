import Foundation

struct ReceiptItem: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var quantity: Int
    var unitPrice: Double
    var discountAmount: Double

    var subtotal: Double { unitPrice * Double(quantity) }
    var totalAfterDiscount: Double { max(subtotal - discountAmount, 0) }
    var hasDiscount: Bool { discountAmount > 0 }
}

struct ReceiptSummary: Identifiable {
    let id = UUID()
    var items: [ReceiptItem]
    /// Always retain OCR output. Structured items are best-effort because every
    /// retailer prints columns differently.
    var rawText: String

    init(items: [ReceiptItem], rawText: String = "") {
        self.items = items
        self.rawText = rawText
    }

    var totalBeforeDiscount: Double { items.reduce(0) { $0 + $1.subtotal } }
    var totalDiscount: Double { items.reduce(0) { $0 + $1.discountAmount } }
    var totalAfterDiscount: Double { max(totalBeforeDiscount - totalDiscount, 0) }
}
