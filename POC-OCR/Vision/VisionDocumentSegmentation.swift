import UIKit
import Vision

final class VisionDocumentSegmentation {
    func detectDocument(image: UIImage) async throws -> DocumentSegmentationResult {
        guard let data = image.jpegData(compressionQuality: 1) else {
            return DocumentSegmentationResult(quadrilateral: nil, confidence: 0, detected: false, failureReason: "Image encoding failed")
        }

        let request = DetectDocumentSegmentationRequest()
        guard let observation = try await request.perform(on: data) else {
            return DocumentSegmentationResult(quadrilateral: nil, confidence: 0, detected: false, failureReason: "No document detected")
        }
        let quadrilateral = DocumentQuadrilateral(
            topLeft: observation.topLeft.cgPoint,
            topRight: observation.topRight.cgPoint,
            bottomRight: observation.bottomRight.cgPoint,
            bottomLeft: observation.bottomLeft.cgPoint
        )
        return DocumentSegmentationResult(
            quadrilateral: quadrilateral,
            confidence: Double(observation.confidence),
            detected: true,
            failureReason: nil
        )
    }
}
