import CoreGraphics
import Foundation

struct ROIResolution: Sendable {
    let rect: CGRect?
    let confidence: ROIConfidence
    let usedFallback: Bool

    /// Structured transaction text produced by RecognizeDocumentsRequest.
    /// This is intentionally optional so the existing OCR path remains the
    /// source of truth when table extraction is unavailable.
    let structuredText: String?

    /// Number of structured table rows selected as the transaction block.
    let transactionRowCount: Int
}

final class ROIDetector {
    func resolve(
        observations: [VisionTextObservation],
        tables: [VisionTableObservation]
    ) -> ROIResolution {
        if let structured = resolveStructuredTable(tables) {
            return structured
        }

        // Preserve the previous text/geometry heuristic as a fallback.
        return resolveLegacy(observations: observations)
    }

    // MARK: - Structured Vision table resolver

    private func resolveStructuredTable(
        _ tables: [VisionTableObservation]
    ) -> ROIResolution? {
        let candidates = tables.compactMap { table -> StructuredCandidate? in
            let rows = normalizedRows(table.rows)
            guard rows.count >= 2 else { return nil }

            guard let startIndex = findTransactionStart(in: rows) else {
                return nil
            }

            let endIndex = findTransactionEnd(in: rows, after: startIndex)
            let selected = Array(rows[startIndex..<endIndex])

            guard selected.count >= 2 else { return nil }

            let transactionBounds = selected
                .map(\.boundingBox)
                .filter { !$0.isNull && !$0.isEmpty }
                .reduce(CGRect.null) { $0.union($1) }

            guard !transactionBounds.isNull, !transactionBounds.isEmpty else {
                return nil
            }

            let numericRows = selected.filter(containsMoneyLikeValue).count
            let numberedRows = selected.filter(isExplicitItemStart).count

            let coverage = Double(selected.count) / Double(max(rows.count, 1))
            let confidence = min(
                0.96,
                0.62
                    + min(Double(numericRows) * 0.04, 0.16)
                    + min(Double(numberedRows) * 0.05, 0.10)
                    + min(coverage * 0.10, 0.10)
            )

            guard confidence >= 0.70 else {
                return nil
            }

            let structuredText = selected
                .map(\.tabSeparatedText)
                .joined(separator: "\n")

            return StructuredCandidate(
                rect: expanded(transactionBounds),
                confidence: confidence,
                rows: selected,
                text: structuredText,
                reason: "RecognizeDocumentsRequest table rows"
            )
        }

        // Prefer the candidate with the strongest transaction evidence,
        // not simply the largest physical table.
        guard let best = candidates.max(by: {
            candidateScore($0) < candidateScore($1)
        }) else {
            return nil
        }

        return ROIResolution(
            rect: best.rect,
            confidence: ROIConfidence(
                value: best.confidence,
                strategy: .table,
                reason: best.reason
            ),
            usedFallback: false,
            structuredText: best.text,
            transactionRowCount: best.rows.count
        )
    }

    private func normalizedRows(
        _ rows: [VisionTableRowObservation]
    ) -> [VisionTableRowObservation] {
        rows
            .filter { !$0.boundingBox.isNull && !$0.boundingBox.isEmpty }
            .sorted {
                if abs($0.boundingBox.maxY - $1.boundingBox.maxY) > 0.005 {
                    return $0.boundingBox.maxY > $1.boundingBox.maxY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
    }

    private func findTransactionStart(
        in rows: [VisionTableRowObservation]
    ) -> Int? {
        // Strongest signal: explicit item numbering such as
        // "01. AMIDIS..." or "1 Double Combo...".
        if let index = rows.firstIndex(where: isExplicitItemStart) {
            return index
        }

        // Secondary signal: a row that contains both product-like text and
        // money/quantity information.
        if let index = rows.firstIndex(where: isLikelyTransactionRow) {
            return index
        }

        return nil
    }

    private func findTransactionEnd(
        in rows: [VisionTableRowObservation],
        after startIndex: Int
    ) -> Int {
        guard startIndex + 1 < rows.count else {
            return rows.count
        }

        for index in (startIndex + 1)..<rows.count {
            if isSummaryBoundary(rows[index]) {
                return index
            }
        }

        return rows.count
    }

    private func isExplicitItemStart(
        _ row: VisionTableRowObservation
    ) -> Bool {
        let text = normalized(row.text)

        return text.range(
            of: #"^\s*\d{1,3}\s*[.)]?\s+\S+"#,
            options: .regularExpression
        ) != nil
    }

    private func isLikelyTransactionRow(
        _ row: VisionTableRowObservation
    ) -> Bool {
        let text = normalized(row.text)
        guard !text.isEmpty, !isSummaryBoundary(row) else {
            return false
        }

        let hasMoney = containsMoneyLikeValue(row)
        let hasQuantity = text.range(
            of: #"\b\d+(?:[.,]\d+)?\s*[xX]\b"#,
            options: .regularExpression
        ) != nil

        let hasProductText = text.range(
            of: #"[A-Za-z]{2,}"#,
            options: .regularExpression
        ) != nil

        return hasProductText && (hasMoney || hasQuantity)
    }

    private func containsMoneyLikeValue(
        _ row: VisionTableRowObservation
    ) -> Bool {
        let text = normalized(row.text)

        // Covers common receipt forms:
        // 2,500
        // 2500
        // RP10000
        // Rp 10.000
        // -1,000
        return text.range(
            of: #"(?:rp\s*)?-?\d{1,3}(?:[.,]\d{3})+(?!\d)|(?:rp\s*)?-?\d{3,}"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isSummaryBoundary(
        _ row: VisionTableRowObservation
    ) -> Bool {
        let text = normalized(row.text)

        let markers = [
            "subtotal",
            "sub total",
            "grand total",
            "total payment",
            "total belanja",
            "payment",
            "qris",
            "cash",
            "change",
            "kembalian",
            "pajak",
            "tax"
        ]

        return markers.contains { text.contains($0) }
    }

    // MARK: - Legacy fallback

    private func resolveLegacy(
        observations: [VisionTextObservation]
    ) -> ROIResolution {
        guard observations.count >= 3 else {
            return fallback("Too few Vision observations")
        }

        let sorted = observations.sorted {
            abs($0.boundingBox.maxY - $1.boundingBox.maxY) > 0.015
                ? $0.boundingBox.maxY > $1.boundingBox.maxY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }

        let start = sorted.firstIndex(where: isLikelyLegacyItemStart)
            ?? sorted.firstIndex {
                $0.text.rangeOfCharacter(from: .decimalDigits) != nil
            }

        guard let start else {
            return fallback("No transaction-like row")
        }

        let end = sorted[(start + 1)...].firstIndex(where: isLikelyLegacySummary)
        let candidate = Array(sorted[start..<(end ?? sorted.endIndex)])

        guard candidate.count >= 2 else {
            return fallback("Transaction block has fewer than two rows")
        }

        let rect = candidate
            .map(\.boundingBox)
            .reduce(CGRect.null) { $0.union($1) }

        let moneyRows = candidate.filter {
            $0.text.contains(where: { $0.isNumber })
        }.count

        let confidence = min(
            0.84,
            0.40
                + Double(candidate.count) * 0.06
                + Double(moneyRows) * 0.03
        )

        guard confidence >= 0.60 else {
            return fallback("Low layout confidence")
        }

        return ROIResolution(
            rect: expanded(rect),
            confidence: ROIConfidence(
                value: confidence,
                strategy: .transactionRows,
                reason: "Legacy rows between transaction start and total"
            ),
            usedFallback: false,
            structuredText: nil,
            transactionRowCount: candidate.count
        )
    }

    private func isLikelyLegacyItemStart(
        _ observation: VisionTextObservation
    ) -> Bool {
        let text = observation.text.lowercased()

        return text.contains("item")
            || text.contains("barang")
            || text.range(
                of: #"^\s*\d{1,3}[.)]"#,
                options: .regularExpression
            ) != nil
    }

    private func isLikelyLegacySummary(
        _ observation: VisionTextObservation
    ) -> Bool {
        [
            "subtotal",
            "sub total",
            "total",
            "pajak",
            "tax",
            "payment",
            "cash",
            "qris",
            "change"
        ].contains {
            observation.text.lowercased().contains($0)
        }
    }

    // MARK: - Helpers

    private struct StructuredCandidate {
        let rect: CGRect
        let confidence: Double
        let rows: [VisionTableRowObservation]
        let text: String
        let reason: String
    }

    private func candidateScore(
        _ candidate: StructuredCandidate
    ) -> Double {
        let numbered = Double(candidate.rows.filter(isExplicitItemStart).count)
        let numeric = Double(candidate.rows.filter(containsMoneyLikeValue).count)

        return candidate.confidence
            + min(numbered * 0.02, 0.10)
            + min(numeric * 0.01, 0.10)
    }

    private func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func expanded(_ rect: CGRect) -> CGRect {
        rect
            .insetBy(dx: -0.04, dy: -0.03)
            .intersection(
                CGRect(x: 0, y: 0, width: 1, height: 1)
            )
    }

    private func fallback(_ reason: String) -> ROIResolution {
        ROIResolution(
            rect: nil,
            confidence: ROIConfidence(
                value: 0.0,
                strategy: .fullDocument,
                reason: reason
            ),
            usedFallback: true,
            structuredText: nil,
            transactionRowCount: 0
        )
    }
}
