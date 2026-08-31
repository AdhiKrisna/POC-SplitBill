import CoreGraphics
import Foundation

struct ROIResolution: Sendable {
    let rect: CGRect?
    let confidence: ROIConfidence
    let usedFallback: Bool
}

final class ROIDetector {
    func resolve(observations: [VisionTextObservation], tableCandidates: [CGRect]) -> ROIResolution {
        if let table = tableCandidates.max(by: { $0.height < $1.height }) {
            return ROIResolution(rect: expanded(table), confidence: ROIConfidence(value: 0.90, strategy: .table, reason: "Vision table candidate"), usedFallback: false)
        }

        guard observations.count >= 3 else { return fallback("Too few Vision observations") }
        let sorted = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        let start = sorted.firstIndex(where: isLikelyItemStart) ?? sorted.firstIndex(where: { $0.text.rangeOfCharacter(from: .decimalDigits) != nil })
        guard let start else { return fallback("No transaction-like row") }
        let end = sorted[(start + 1)...].firstIndex(where: isLikelySummary)
        let candidate = Array(sorted[start..<(end ?? sorted.endIndex)])
        guard candidate.count >= 2 else { return fallback("Transaction block has fewer than two rows") }

        let rect = candidate.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        let moneyRows = candidate.filter { $0.text.contains(where: { $0.isNumber }) }.count
        let confidence = min(0.84, 0.40 + Double(candidate.count) * 0.06 + Double(moneyRows) * 0.03)
        guard confidence >= 0.60 else { return fallback("Low layout confidence") }
        return ROIResolution(rect: expanded(rect), confidence: ROIConfidence(value: confidence, strategy: .transactionRows, reason: "Rows between transaction start and total"), usedFallback: false)
    }

    private func expanded(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -0.04, dy: -0.03).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func fallback(_ reason: String) -> ROIResolution {
        ROIResolution(rect: nil, confidence: ROIConfidence(value: 0.0, strategy: .fullDocument, reason: reason), usedFallback: true)
    }

    private func isLikelyItemStart(_ observation: VisionTextObservation) -> Bool {
        let text = observation.text.lowercased()
        return text.contains("item") || text.contains("barang") || text.range(of: #"^\s*\d{1,3}[.)]"#, options: .regularExpression) != nil
    }

    private func isLikelySummary(_ observation: VisionTextObservation) -> Bool {
        ["subtotal", "sub total", "total", "pajak", "tax", "payment", "cash", "qris"].contains { observation.text.lowercased().contains($0) }
    }
}
