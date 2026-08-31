enum ROIStrategy: String, Sendable, Hashable {
    case table = "vision_table"
    case transactionRows = "transaction_rows"
    case textHeuristics = "text_layout_heuristics"
    case fullDocument = "full_document_fallback"
}
