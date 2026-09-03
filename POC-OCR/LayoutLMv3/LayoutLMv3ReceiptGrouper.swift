import CoreGraphics
import Foundation

enum LayoutLMv3ReconstructionStatus: String, Codable, Sendable {
    case success
    case failedEntityExtraction = "failed_entity_extraction"
    case failedReconstruction = "failed_reconstruction"
}

struct LayoutLMv3WordPrediction: Codable, Sendable {
    let wordIndex: Int
    let text: String
    let bbox: [Int]
    let labelID: Int
    let label: String
    let confidence: Float
    let sourceTokenIndex: Int
    let subwordTokenIndices: [Int]
}

struct LayoutLMv3EntityTrace: Codable, Sendable {
    let type: String
    let text: String
    let wordIndices: [Int]
    let bbox: [Int]
}

struct LayoutLMv3ItemTrace: Codable, Sendable {
    let name: String
    let quantity: Int
    let unitPrice: Double
    let lineTotal: Double
    let itemRowIndex: Int
    let attachedNumericRowIndices: [Int]
}

struct LayoutLMv3ReconstructionTrace: Codable, Sendable {
    let ocrWordCount: Int
    let predictedWordCount: Int
    let nonOWordCount: Int
    let entityCounts: [String: Int]
    let reconstructedItemCount: Int
    let status: LayoutLMv3ReconstructionStatus
    let wordPredictions: [LayoutLMv3WordPrediction]
    let entities: [LayoutLMv3EntityTrace]
    let items: [LayoutLMv3ItemTrace]
}

struct LayoutLMv3GroupingResult: Sendable {
    let items: [ReceiptItem]
    let trace: LayoutLMv3ReconstructionTrace
}

struct LayoutLMv3ReceiptGrouper {
    func group(words: [OCRWord], predictions: [TokenPrediction]) -> [ReceiptItem] {
        groupWithTrace(words: words, predictions: predictions).items
    }

    func groupWithTrace(
        words: [OCRWord],
        predictions: [TokenPrediction]
    ) -> LayoutLMv3GroupingResult {
        let wordPredictions = aggregateFirstSubword(words: words, predictions: predictions)
        let labeledWords = wordPredictions.compactMap { prediction -> LabeledWord? in
            guard prediction.label != "O", words.indices.contains(prediction.wordIndex) else {
                return nil
            }
            return LabeledWord(
                wordIndex: prediction.wordIndex,
                word: words[prediction.wordIndex],
                label: prediction.label
            )
        }
        let entities = makeEntities(from: wordPredictions)
        let rows = makeRows(labeledWords)
        let reconstructed = reconstruct(rows: rows)
        let entityCounts = Dictionary(grouping: entities, by: \.type)
            .mapValues(\.count)
        let status: LayoutLMv3ReconstructionStatus
        if reconstructed.items.isEmpty {
            status = entityCounts["ITEM", default: 0] == 0
                ? .failedEntityExtraction
                : .failedReconstruction
        } else {
            status = .success
        }
        return LayoutLMv3GroupingResult(
            items: reconstructed.items,
            trace: LayoutLMv3ReconstructionTrace(
                ocrWordCount: words.count,
                predictedWordCount: wordPredictions.count,
                nonOWordCount: labeledWords.count,
                entityCounts: entityCounts,
                reconstructedItemCount: reconstructed.items.count,
                status: status,
                wordPredictions: wordPredictions,
                entities: entities,
                items: reconstructed.traces
            )
        )
    }

    /// Matches Hugging Face evaluation and `only_label_first_subword=true`.
    private func aggregateFirstSubword(
        words: [OCRWord],
        predictions: [TokenPrediction]
    ) -> [LayoutLMv3WordPrediction] {
        Dictionary(grouping: predictions.compactMap { prediction in
            prediction.wordIndex.map { ($0, prediction) }
        }, by: \.0)
        .compactMap { wordIndex, values -> LayoutLMv3WordPrediction? in
            guard words.indices.contains(wordIndex) else { return nil }
            let ordered = values.map(\.1).sorted { $0.tokenIndex < $1.tokenIndex }
            guard let first = ordered.first else { return nil }
            return LayoutLMv3WordPrediction(
                wordIndex: wordIndex,
                text: words[wordIndex].text,
                bbox: normalizedBox(words[wordIndex].boundingBox),
                labelID: first.labelID,
                label: first.label,
                confidence: first.confidence,
                sourceTokenIndex: first.tokenIndex,
                subwordTokenIndices: ordered.map(\.tokenIndex)
            )
        }
        .sorted { $0.wordIndex < $1.wordIndex }
    }

    private func makeEntities(
        from predictions: [LayoutLMv3WordPrediction]
    ) -> [LayoutLMv3EntityTrace] {
        var result: [LayoutLMv3EntityTrace] = []
        var currentType: String?
        var current: [LayoutLMv3WordPrediction] = []

        func flush() {
            guard let type = currentType, !current.isEmpty else { return }
            result.append(LayoutLMv3EntityTrace(
                type: type,
                text: current.map(\.text).joined(separator: " "),
                wordIndices: current.map(\.wordIndex),
                bbox: union(current.map(\.bbox))
            ))
            currentType = nil
            current = []
        }

        for prediction in predictions {
            guard prediction.label != "O",
                  let separator = prediction.label.firstIndex(of: "-") else {
                flush()
                continue
            }
            let prefix = String(prediction.label[..<separator])
            let type = String(prediction.label[prediction.label.index(after: separator)...])
            if prefix == "B" || type != currentType {
                flush()
                currentType = type
            }
            current.append(prediction)
        }
        flush()
        return result
    }

    private func makeRows(_ words: [LabeledWord]) -> [SemanticRow] {
        let ordered = words.sorted {
            $0.word.boundingBox.midY == $1.word.boundingBox.midY
                ? $0.word.boundingBox.minX < $1.word.boundingBox.minX
                : $0.word.boundingBox.midY < $1.word.boundingBox.midY
        }
        var rows: [[LabeledWord]] = []
        for word in ordered {
            guard let last = rows.indices.last else {
                rows.append([word])
                continue
            }
            let center = rows[last].map { $0.word.boundingBox.midY }
                .reduce(0, +) / CGFloat(rows[last].count)
            let rowHeight = rows[last].map { $0.word.boundingBox.height }.max() ?? 0
            let tolerance = max(0.012, max(rowHeight, word.word.boundingBox.height) * 0.65)
            if abs(center - word.word.boundingBox.midY) <= tolerance {
                rows[last].append(word)
            } else {
                rows.append([word])
            }
        }
        return rows.enumerated().map { index, words in
            SemanticRow(
                index: index,
                words: words.sorted { $0.word.boundingBox.minX < $1.word.boundingBox.minX }
            )
        }
    }

    private func reconstruct(rows: [SemanticRow]) -> (
        items: [ReceiptItem],
        traces: [LayoutLMv3ItemTrace]
    ) {
        let itemRows = rows.filter { !$0.text(for: "ITEM").isEmpty }
        guard !itemRows.isEmpty else { return ([], []) }

        var numericAssignments: [Int: [SemanticRow]] = [:]
        let numericRows = rows.filter { $0.text(for: "ITEM").isEmpty && $0.hasNumeric }
        let pairCount = min(itemRows.count, numericRows.count)
        let orderedOffsets = (0..<pairCount).map {
            numericRows[$0].centerY - itemRows[$0].centerY
        }
        let typicalOffset = median(orderedOffsets)
        let usesOrderedPairing = pairCount > 1 && abs(typicalOffset) > 0.005

        for (numericIndex, numericRow) in numericRows.enumerated() {
            if usesOrderedPairing, numericIndex < itemRows.count {
                let orderedItem = itemRows[numericIndex]
                let maxDistance = max(0.12, max(orderedItem.height, numericRow.height) * 5)
                if abs(orderedItem.centerY - numericRow.centerY) <= maxDistance {
                    numericAssignments[orderedItem.index, default: []].append(numericRow)
                    continue
                }
            }
            guard let nearest = itemRows.min(by: {
                abs($0.centerY - numericRow.centerY) < abs($1.centerY - numericRow.centerY)
            }) else { continue }
            let maxDistance = max(0.08, max(nearest.height, numericRow.height) * 4)
            if abs(nearest.centerY - numericRow.centerY) <= maxDistance {
                numericAssignments[nearest.index, default: []].append(numericRow)
            }
        }

        var items: [ReceiptItem] = []
        var traces: [LayoutLMv3ItemTrace] = []
        for itemRow in itemRows {
            let attachedRows = [itemRow] + (numericAssignments[itemRow.index] ?? [])
            let itemText = itemRow.text(for: "ITEM")
            let quantityText = joinedText(for: "QTY", rows: attachedRows)
            let unitPriceText = joinedText(for: "UNIT_PRICE", rows: attachedRows)
            let lineTotalText = joinedText(for: "LINE_TOTAL", rows: attachedRows)
            let quantity = max(Int(number(from: quantityText) ?? 1), 1)
            let lineTotal = money(from: lineTotalText)
            let explicitUnitPrice = money(from: unitPriceText)
            guard !itemText.isEmpty,
                  let unitPrice = explicitUnitPrice ?? lineTotal.map({ $0 / Double(quantity) }),
                  unitPrice > 0 else {
                continue
            }
            let item = ReceiptItem(
                name: itemText,
                quantity: quantity,
                unitPrice: unitPrice,
                discountAmount: 0
            )
            items.append(item)
            traces.append(LayoutLMv3ItemTrace(
                name: itemText,
                quantity: quantity,
                unitPrice: unitPrice,
                lineTotal: lineTotal ?? unitPrice * Double(quantity),
                itemRowIndex: itemRow.index,
                attachedNumericRowIndices: attachedRows.dropFirst().map(\.index)
            ))
        }
        return (items, traces)
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private func joinedText(for entity: String, rows: [SemanticRow]) -> String {
        rows.map { $0.text(for: entity) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func number(from text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        return Double(normalized.filter { $0.isNumber || $0 == "." })
    }

    private func money(from text: String) -> Double? {
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Double(digits)
    }

    private func union(_ boxes: [[Int]]) -> [Int] {
        guard let first = boxes.first else { return [0, 0, 0, 0] }
        return boxes.dropFirst().reduce(first) { value, box in
            [
                min(value[0], box[0]),
                min(value[1], box[1]),
                max(value[2], box[2]),
                max(value[3], box[3]),
            ]
        }
    }

    private func normalizedBox(_ rect: CGRect) -> [Int] {
        let x0 = min(1000, max(0, Int((rect.minX * 1000).rounded())))
        let y0 = min(1000, max(0, Int((rect.minY * 1000).rounded())))
        let x1 = max(x0, min(1000, max(0, Int((rect.maxX * 1000).rounded()))))
        let y1 = max(y0, min(1000, max(0, Int((rect.maxY * 1000).rounded()))))
        return [x0, y0, x1, y1]
    }
}

private struct LabeledWord {
    let wordIndex: Int
    let word: OCRWord
    let label: String
}

private struct SemanticRow {
    let index: Int
    let words: [LabeledWord]

    var centerY: CGFloat {
        words.map { $0.word.boundingBox.midY }.reduce(0, +) / CGFloat(max(words.count, 1))
    }

    var height: CGFloat {
        words.map { $0.word.boundingBox.height }.max() ?? 0
    }

    var hasNumeric: Bool {
        ["QTY", "UNIT_PRICE", "LINE_TOTAL"].contains { !text(for: $0).isEmpty }
    }

    func text(for entity: String) -> String {
        words.filter { $0.label.hasSuffix("-\(entity)") }
            .map { $0.word.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
