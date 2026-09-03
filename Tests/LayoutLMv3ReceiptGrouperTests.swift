import Foundation

@main
enum LayoutLMv3ReceiptGrouperTests {
    static func main() {
        testFirstSubwordWins()
        testNumericRowAboveItemRow()
        testOrderedNumericRowsDoNotDriftBackward()
        testSameRowQuantityUnitAndTotal()
        testSameRowLineTotalDerivesUnitPrice()
        testModifierRowsWithoutPricesAreNotProducts()
        print("LayoutLMv3ReceiptGrouperTests: 6 passed")
    }

    private static func testFirstSubwordWins() {
        let words = [word("AMIDIS", 0.10, 0.10), word("10.000", 0.75, 0.10)]
        let predictions = [
            prediction(1, 0, "B-ITEM", 1, confidence: 0.70),
            prediction(2, 0, "O", 0, confidence: 0.99),
            prediction(3, 0, "B-QTY", 3, confidence: 0.98),
            prediction(4, 1, "B-LINE_TOTAL", 7),
        ]
        let result = LayoutLMv3ReceiptGrouper().groupWithTrace(
            words: words,
            predictions: predictions
        )
        expect(result.trace.wordPredictions[0].label == "B-ITEM", "first subword must win")
        expect(result.items.first?.name == "AMIDIS", "AMIDIS must stay one product entity")
    }

    private static func testNumericRowAboveItemRow() {
        let words = [
            word("1x", 0.05, 0.10), word("10000", 0.35, 0.10),
            word("RP10000", 0.72, 0.10), word("Es", 0.05, 0.15),
            word("jeruk", 0.18, 0.15),
        ]
        let labels = ["B-QTY", "B-UNIT_PRICE", "B-LINE_TOTAL", "B-ITEM", "I-ITEM"]
        let result = group(words, labels)
        expect(result.items.count == 1, "numeric row above item must reconstruct")
        expect(result.items[0].name == "Es jeruk", "multi-word item name must merge")
        expect(result.items[0].quantity == 1, "quantity 1x must parse")
        expect(result.items[0].unitPrice == 10_000, "unit price must attach from row above")
    }

    private static func testSameRowQuantityUnitAndTotal() {
        let words = [
            word("AMIDIS", 0.05, 0.20), word("AIR", 0.18, 0.20),
            word("MINERAL", 0.28, 0.20), word("1.000", 0.55, 0.20),
            word("2,500", 0.70, 0.20), word("2,500", 0.85, 0.20),
        ]
        let labels = ["B-ITEM", "I-ITEM", "I-ITEM", "B-QTY", "B-UNIT_PRICE", "B-LINE_TOTAL"]
        let result = group(words, labels)
        expect(result.items.first?.name == "AMIDIS AIR MINERAL", "same-row item must merge")
        expect(result.items.first?.quantity == 1, "decimal-looking quantity must parse as one")
        expect(result.items.first?.unitPrice == 2_500, "same-row unit price must parse")
    }

    private static func testOrderedNumericRowsDoNotDriftBackward() {
        let words = [
            word("1x", 0.05, 0.10), word("10000", 0.35, 0.10),
            word("Es", 0.05, 0.13), word("jeruk", 0.18, 0.13),
            word("1x", 0.05, 0.16), word("9000", 0.35, 0.16),
            word("Kukubima", 0.05, 0.20), word("susu", 0.28, 0.20),
        ]
        let labels = [
            "B-QTY", "B-LINE_TOTAL", "B-ITEM", "I-ITEM",
            "B-QTY", "B-LINE_TOTAL", "B-ITEM", "I-ITEM",
        ]
        let result = group(words, labels)
        expect(result.items.count == 2, "ordered alternating rows must produce two items")
        expect(result.items[0].unitPrice == 10_000, "first numeric row must pair with first item")
        expect(result.items[1].unitPrice == 9_000, "second numeric row must pair with second item")
    }

    private static func testSameRowLineTotalDerivesUnitPrice() {
        let words = [
            word("Sup", 0.05, 0.30), word("Ayam", 0.16, 0.30),
            word("2", 0.60, 0.30), word("47,274", 0.82, 0.30),
        ]
        let labels = ["B-ITEM", "I-ITEM", "B-QTY", "B-LINE_TOTAL"]
        let result = group(words, labels)
        expect(result.items.first?.quantity == 2, "quantity two must parse")
        expect(result.items.first?.unitPrice == 23_637, "unit price must derive from line total")
    }

    private static func testModifierRowsWithoutPricesAreNotProducts() {
        let words = [
            word("1", 0.05, 0.40), word("Double", 0.12, 0.40),
            word("Combo", 0.28, 0.40), word("Fire", 0.42, 0.40),
            word("Parmesan", 0.53, 0.40), word("80,000", 0.84, 0.40),
            word("1x", 0.05, 0.45), word("Fire", 0.16, 0.45),
            word("Chicken", 0.28, 0.45), word("1x", 0.05, 0.50),
            word("BBQ", 0.16, 0.50), word("Sauce", 0.28, 0.50),
        ]
        let labels = [
            "B-QTY", "B-ITEM", "I-ITEM", "I-ITEM", "I-ITEM", "B-LINE_TOTAL",
            "B-QTY", "B-ITEM", "I-ITEM", "B-QTY", "B-ITEM", "I-ITEM",
        ]
        let result = group(words, labels)
        expect(result.items.count == 1, "modifier rows without prices must not become products")
        expect(result.items[0].name == "Double Combo Fire Parmesan", "main combo must survive")
        expect(result.items[0].unitPrice == 80_000, "combo total must populate product")
    }

    private static func group(
        _ words: [OCRWord],
        _ labels: [String]
    ) -> LayoutLMv3GroupingResult {
        let predictions = labels.enumerated().map { index, label in
            prediction(index + 1, index, label, labelID(label))
        }
        return LayoutLMv3ReceiptGrouper().groupWithTrace(
            words: words,
            predictions: predictions
        )
    }

    private static func word(_ text: String, _ x: CGFloat, _ y: CGFloat) -> OCRWord {
        OCRWord(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: 0.10, height: 0.025),
            confidence: 1
        )
    }

    private static func prediction(
        _ tokenIndex: Int,
        _ wordIndex: Int,
        _ label: String,
        _ labelID: Int,
        confidence: Float = 0.9
    ) -> TokenPrediction {
        TokenPrediction(
            tokenIndex: tokenIndex,
            token: "token",
            wordIndex: wordIndex,
            labelID: labelID,
            label: label,
            confidence: confidence
        )
    }

    private static func labelID(_ label: String) -> Int {
        [
            "O": 0, "B-ITEM": 1, "I-ITEM": 2, "B-QTY": 3, "I-QTY": 4,
            "B-UNIT_PRICE": 5, "I-UNIT_PRICE": 6,
            "B-LINE_TOTAL": 7, "I-LINE_TOTAL": 8,
        ][label]!
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
