import Foundation
import ImageIO
import UIKit
import Vision

enum ReceiptExtractionError: LocalizedError {
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .noTextFound:
            return "Teks pada struk tidak terbaca. Coba foto lebih dekat, terang, dan tidak miring."
        }
    }
}

protocol ReceiptExtractionService {
    func extract(from image: UIImage) async throws -> ReceiptSummary
}

/// Vision's document model supplies rows and table cells before Swift parses the
/// monetary fields. This avoids merging adjacent receipt lines by hand
///
class VisionReceiptExtractionService: ReceiptExtractionService {
    func extract(from image: UIImage) async throws -> ReceiptSummary {
        let lines = try await recognizeLines(in: image)
        guard !lines.isEmpty else { throw ReceiptExtractionError.noTextFound }

        let rawText = lines.map(\.text).joined(separator: "\n")
        // Parsing is intentionally optional. A receipt with an unfamiliar table
        // layout must still return its OCR text instead of being rejected.
        return ReceiptSummary(items: ReceiptLineParser().parse(lines), rawText: rawText)
    }

    private func recognizeLines(in image: UIImage) async throws -> [RecognizedLine] {
        if let documentLines = try? await recognizeDocumentLines(in: image), !documentLines.isEmpty {
            return documentLines
        }
        return try await recognizeLegacyLines(in: image)
    }

    /// Prefer the iOS document-recognition model. It identifies tables and keeps
    /// the cells in a row together, which fits retail receipts better than a
    /// generic text request.
    private func recognizeDocumentLines(in image: UIImage) async throws -> [RecognizedLine] {
        guard let data = image.jpegData(compressionQuality: 1) else {
            throw ReceiptExtractionError.noTextFound
        }

        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: data)
        let documents = observations.map(\.document)

        let tableRows = documents
            .flatMap(\.tables)
            .flatMap(\.rows)
            .compactMap { row -> RecognizedLine? in
                let cells = row.map { $0.content.text.transcript }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !cells.isEmpty else { return nil }
                return RecognizedLine(text: cells.joined(separator: " "), box: .zero)
            }

        if !tableRows.isEmpty {
            return tableRows
        }

        return documents
            .flatMap { $0.text.lines }
            .map { RecognizedLine(text: $0.transcript, box: .zero) }
    }

    /// Some thermal receipts don't register as a table. Keep the older text OCR
    /// as a fallback, but do not merge rows with a fixed Y-axis threshold.
    private func recognizeLegacyLines(in image: UIImage) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { throw ReceiptExtractionError.noTextFound }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { observation -> RecognizedLine? in
                        guard let text = observation.topCandidates(1).first?.string else { return nil }
                        return RecognizedLine(text: text, box: observation.boundingBox)
                    }
                    // Vision does not promise `results` are in receipt order.
                    .sorted { lhs, rhs in
                        abs(lhs.box.maxY - rhs.box.maxY) > 0.015
                            ? lhs.box.maxY > rhs.box.maxY
                            : lhs.box.minX < rhs.box.minX
                    }
                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Indonesian is not an OCR language on every Vision runtime. Retail
            // receipts use Latin characters, and en-US is reliably supported.
            request.recognitionLanguages = ["en-US"]

            do {
                try VNImageRequestHandler(
                    cgImage: cgImage,
                    orientation: CGImagePropertyOrientation(image.imageOrientation),
                    options: [:]
                ).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

}

private struct RecognizedLine {
    let text: String
    let box: CGRect
}

private struct ReceiptLineParser {
    private let itemStart = try! NSRegularExpression(pattern: #"^\s*\d{1,3}\s*[.)]\s*(.+)$"#)
    private let priceLine = try! NSRegularExpression(
        pattern: #"(-?[0-9][0-9.,]*)\s*[xX×]\s*(-?[0-9][0-9.,]*)\s+(-?[0-9][0-9.,]*)"#
    )
    private let simpleItemLine = try! NSRegularExpression(
        pattern: #"^\s*(.+?[A-Za-z].*?)\s+(\d{1,3})\s+(-?[0-9][0-9.,]*)\s*$"#
    )

    func parse(_ lines: [RecognizedLine]) -> [ReceiptItem] {
        var items: [ReceiptItem] = []
        var pendingName: String?

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let simpleItem = simpleItem(in: text) {
                items.append(simpleItem)
                pendingName = nil
                continue
            }

            if let name = itemName(in: text) {
                pendingName = name
            } else if pendingName != nil, !hasPrice(in: text), isLikelyNameContinuation(text) {
                pendingName = "\(pendingName!) \(text)"
            }

            guard let name = pendingName, let values = priceValues(in: text) else { continue }
            pendingName = nil

            let quantity = quantity(from: values.quantity)
            let unitPrice = rupiah(from: values.unitPrice)
            let lineTotal = rupiah(from: values.lineTotal)
            let isDiscount = name.localizedCaseInsensitiveContains("discount")
                || name.localizedCaseInsensitiveContains("diskon")
                || lineTotal < 0

            if isDiscount {
                items.append(ReceiptItem(name: name, quantity: quantity, unitPrice: 0, discountAmount: abs(lineTotal)))
            } else {
                items.append(ReceiptItem(name: name, quantity: quantity, unitPrice: max(unitPrice, 0), discountAmount: 0))
            }
        }
        return items
    }

    private func itemName(in text: String) -> String? {
        guard let match = itemStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var name = String(text[range]).trimmingCharacters(in: .whitespaces)
        // A document-table row can contain the item header and prices in the
        // same row. Keep only the header portion as the item name.
        if let priceMatch = priceLine.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let priceStart = Range(priceMatch.range, in: name)?.lowerBound {
            name = String(name[..<priceStart]).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? nil : name
    }

    private func simpleItem(in text: String) -> ReceiptItem? {
        guard let match = simpleItemLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let quantityRange = Range(match.range(at: 2), in: text),
              let amountRange = Range(match.range(at: 3), in: text) else { return nil }

        let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
        guard !isSummaryLabel(name) else { return nil }
        let quantity = max(Int(text[quantityRange]) ?? 1, 1)
        let amount = rupiah(from: String(text[amountRange]))
        guard amount != 0 else { return nil }
        return ReceiptItem(name: name, quantity: quantity, unitPrice: abs(amount) / Double(quantity), discountAmount: amount < 0 ? abs(amount) : 0)
    }

    private func hasPrice(in text: String) -> Bool {
        priceLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func priceValues(in text: String) -> (quantity: String, unitPrice: String, lineTotal: String)? {
        guard let match = priceLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let values = (1...3).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard values.count == 3 else { return nil }
        return (values[0], values[1], values[2])
    }

    private func quantity(from raw: String) -> Int {
        // POS systems commonly print one item as `1.000`; prices must not use this rule.
        let integerPart = raw.drop(while: { $0 == "-" }).split(whereSeparator: { $0 == "." || $0 == "," }).first
        return max(Int(integerPart ?? "") ?? 1, 1)
    }

    private func rupiah(from raw: String) -> Double {
        let digits = raw.filter(\.isNumber)
        let value = Double(digits) ?? 0
        return raw.hasPrefix("-") ? -value : value
    }

    private func isLikelyNameContinuation(_ text: String) -> Bool {
        !text.contains(":") && text.rangeOfCharacter(from: .letters) != nil
    }

    private func isSummaryLabel(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return ["total", "subtotal", "tax", "change", "cash", "rounding", "payment", "qris"].contains {
            normalized.contains($0)
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
