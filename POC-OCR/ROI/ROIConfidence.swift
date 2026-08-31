import Foundation

struct ROIConfidence: Sendable, Hashable {
    let value: Double
    let strategy: ROIStrategy
    let reason: String

    var isReliable: Bool { value >= 0.60 }
}
