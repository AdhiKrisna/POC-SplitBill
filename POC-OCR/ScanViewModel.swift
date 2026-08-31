import Foundation
import UIKit
internal import Combine

@MainActor
final class ScanViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case extracting
        case result
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var images: [UIImage] = []
    @Published private(set) var results: [ExtractionResult] = []
    @Published private(set) var completedCount = 0
    @Published var extractionMode: ExtractionMode = .roiRegex
    @Published var preprocessingMode: DocumentPreprocessingMode = .original

    var previewImage: UIImage? { images.first }
    private let pipeline = ReceiptExtractionPipeline()

    func setImages(_ images: [UIImage]) {
        self.images = images
        results = []
        completedCount = 0
        state = .idle
    }

    func extract() {
        guard !images.isEmpty, state != .extracting else { return }
        let input = images
        state = .extracting
        results = []
        completedCount = 0

        Task {
            var extracted: [ExtractionResult] = []
            var failures: [String] = []

            for (index, image) in input.enumerated() {
                do {
                    extracted.append(try await pipeline.extract(image: image, mode: extractionMode, preprocessing: preprocessingMode))
                } catch {
                    failures.append("Foto \(index + 1): \(error.localizedDescription)")
                }
                completedCount = index + 1
            }

            results = extracted
            state = extracted.isEmpty
                ? .failed(failures.joined(separator: "\n"))
                : .result
        }
    }

    func reset() {
        images = []
        results = []
        completedCount = 0
        state = .idle
    }
}
