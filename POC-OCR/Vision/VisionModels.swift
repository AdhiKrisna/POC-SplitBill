import CoreGraphics
import Foundation

struct VisionTextObservation: Sendable, Hashable {
    let text: String
    /// Vision's normalized coordinate space, with the origin at bottom-left.
    let boundingBox: CGRect
    let confidence: Float
}

struct VisionDocumentLayout: Sendable {
    let observations: [VisionTextObservation]
    let tables: [CGRect]

    var fullText: String { observations.map(\.text).joined(separator: "\n") }
}
