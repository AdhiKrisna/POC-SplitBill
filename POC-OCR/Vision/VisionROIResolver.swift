import UIKit

final class VisionROIResolver {
    private let detector = ROIDetector()

    func resolve(layout: VisionDocumentLayout) -> ROIResolution {
        detector.resolve(observations: layout.observations, tableCandidates: layout.tables)
    }
}
