import CoreGraphics
import Foundation

struct DocumentQuadrilateral: Sendable, Hashable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    /// The smallest axis-aligned rect is only used by the non-rectifying crop mode.
    var boundingRect: CGRect {
        [topLeft, topRight, bottomRight, bottomLeft].reduce(CGRect.null) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }
}

struct DocumentSegmentationResult: Sendable {
    let quadrilateral: DocumentQuadrilateral?
    let confidence: Double
    let detected: Bool
    let failureReason: String?

    var isReliable: Bool {
        detected && quadrilateral != nil && confidence >= 0.45
    }
}

struct VisionTextObservation: Sendable, Hashable {
    let text: String
    /// Vision's normalized coordinate space, with the origin at bottom-left.
    let boundingBox: CGRect
    let confidence: Float
}

/// Structured table information returned by RecognizeDocumentsRequest.
/// We intentionally convert Apple's Vision types into project-owned value
/// types so the rest of the pipeline does not depend on Vision's container types.
struct VisionTableObservation: Sendable {
    let boundingBox: CGRect
    let rows: [VisionTableRowObservation]
}

struct VisionTableRowObservation: Sendable {
    let boundingBox: CGRect
    let cells: [VisionTableCellObservation]

    var text: String {
        cells.map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }

    var tabSeparatedText: String {
        cells.map(\.text)
            .joined(separator: "\t")
    }
}

struct VisionTableCellObservation: Sendable {
    let text: String
    let boundingBox: CGRect
}

struct VisionDocumentLayout: Sendable {
    let observations: [VisionTextObservation]
    let tables: [VisionTableObservation]

    var fullText: String {
        observations.map(\.text).joined(separator: "\n")
    }
}
