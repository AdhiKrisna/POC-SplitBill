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
    @Published private(set) var summaries: [ReceiptSummary] = []
    @Published private(set) var completedCount = 0

    var previewImage: UIImage? { images.first }

    private let service: ReceiptExtractionService

    init() {
        self.service = VisionReceiptExtractionService()
    }

    init(service: ReceiptExtractionService) {
        self.service = service
    }

    func setImages(_ images: [UIImage]) {
        self.images = images
        summaries = []
        completedCount = 0
        state = .idle
    }

    func extract() {
        guard !images.isEmpty, state != .extracting else { return }
        let input = images
        state = .extracting
        summaries = []
        completedCount = 0

        Task {
            var extracted: [ReceiptSummary] = []
            var failures: [String] = []

            for (index, image) in input.enumerated() {
                do {
                    extracted.append(try await service.extract(from: image))
                } catch {
                    failures.append("Foto \(index + 1): \(error.localizedDescription)")
                }
                completedCount = index + 1
            }

            summaries = extracted
            state = extracted.isEmpty
                ? .failed(failures.joined(separator: "\n"))
                : .result
        }
    }

    func reset() {
        images = []
        summaries = []
        completedCount = 0
        state = .idle
    }
}
