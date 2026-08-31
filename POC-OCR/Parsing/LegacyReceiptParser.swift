import Foundation

struct LegacyReceiptParser {
    func parse(_ observations: [VisionTextObservation]) -> [ReceiptItem] {
        var items: [ReceiptItem] = []
        let pattern = #"^\s*(.+?[A-Za-z].*?)\s+(\d{1,3})\s+(-?[0-9][0-9.,]*)\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for observation in observations {
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let nameRange = Range(match.range(at: 1), in: text), let quantityRange = Range(match.range(at: 2), in: text), let amountRange = Range(match.range(at: 3), in: text) else { continue }
            let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
            guard !["total", "subtotal", "tax", "payment", "cash", "qris"].contains(where: { name.lowercased().contains($0) }) else { continue }
            let quantity = max(Int(text[quantityRange]) ?? 1, 1)
            let amountText = String(text[amountRange])
            let amount = Double(amountText.filter(\.isNumber)) ?? 0
            guard amount > 0 else { continue }
            items.append(ReceiptItem(name: name, quantity: quantity, unitPrice: amount / Double(quantity), discountAmount: 0))
        }
        return items
    }
}
