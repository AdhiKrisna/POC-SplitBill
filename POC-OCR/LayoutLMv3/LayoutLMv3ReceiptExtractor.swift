@preconcurrency import CoreML
import Foundation
import UIKit

enum LayoutLMv3ModelVersion {
    case v1
    case v2
}

enum LayoutLMv3ExtractionError: LocalizedError {
    case missingModel
    case missingTokenizer
    case missingLabels
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "LayoutLMv3 model is missing from the app target."

        case .missingTokenizer:
            return "LayoutLMv3 tokenizer/config is missing from the app target."

        case .missingLabels:
            return "LayoutLMv3 labels are missing from the app target."
        case .inferenceFailed(let reason):
            return "Core ML LayoutLMv3 inference failed: \(reason)"
        }
    }
}

struct LayoutLMv3ExtractionOutput {
    let words: [OCRWord]
    let tokenPredictions: [TokenPrediction]
    let debugExport: LayoutLMv3DebugExport
    let items: [ReceiptItem]
}

final class LayoutLMv3ReceiptExtractor {
    private let version: LayoutLMv3ModelVersion

    private let ocr = VisionDocumentRecognizer()
    private let inputBuilder = LayoutLMv3InputBuilder()
    private let grouper = LayoutLMv3ReceiptGrouper()
    private var extractionMode: ExtractionMode {
        switch version {
        case .v1:
            return .visionLayoutLMv3
        case .v2:
            return .visionLayoutLMv3V2
        }
    }
    init(version: LayoutLMv3ModelVersion) {
        self.version = version
    }
    /// The caller must supply the full rectified receipt. The main app route
    /// does this through ReceiptExtractionPipeline before calling `predict`.
    func extract(from image: UIImage) async throws -> ExtractionResult {
        let observations = try await ocr.recognizeText(in: image)
        guard !observations.isEmpty else { throw LayoutLMv3InputError.noWords }
        let output = try await predict(from: image, observations: observations)
        let rawText = observations.map(\.text).joined(separator: "\n")
        let diagnostics = ExtractionDiagnostics(
            extractionMode: extractionMode,
            
            documentDetected: false,
            documentConfidence: 0,
            documentQuadrilateral: nil,
            documentFallback: "direct_extractor_assumes_pre_rectified_input",
            rectifiedImageSize: image.size,
            requestedROI: false,
            roiRect: nil,
            roiConfidence: ROIConfidence(value: 0, strategy: .fullDocument, reason: "Not requested"),
            roiUsed: false,
            roiFallback: nil,
            roiStrategy: .fullDocument,
            transactionRowCount: output.items.count,
            structuredTransactionText: nil,
            layoutObservationCount: observations.count,
            ocrObservationCount: observations.count,
            foundationInput: "Not requested",
            foundationOutput: "Not requested"
        )
        return ExtractionResult(
            summary: ReceiptSummary(items: output.items, rawText: rawText),
            diagnostics: diagnostics,
            preprocessedImage: nil,
            ocrImage: image,
            ocrObservations: observations,
            layoutLMv3Image: image,
            layoutLMv3Observations: observations,
            layoutLMv3DocumentScope: .fullRectifiedDocument,
            layoutLMv3Predictions: output.tokenPredictions,
            layoutLMv3DebugExport: output.debugExport
        )
    }

    func predict(
        from image: UIImage,
        observations: [VisionTextObservation]
    ) async throws -> LayoutLMv3ExtractionOutput {
        let words = try inputBuilder.words(from: observations)
        let resources = try resourceURLs()
        let tokenizer = try LayoutLMv3Tokenizer(
            url: resources.tokenizer,
            configURL: resources.tokenizerConfig
        )
        let decoder = try LayoutLMv3LabelDecoder(url: resources.labels)
        let prepared = try inputBuilder.build(image: image, words: words, tokenizer: tokenizer)

        let logits: MLMultiArray
        do {
            logits = try await Task.detached(priority: .userInitiated) {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .all
                let model = try MLModel(contentsOf: resources.model, configuration: configuration)
                let provider = try await MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: prepared.inputIDs),
                    "attention_mask": MLFeatureValue(multiArray: prepared.attentionMask),
                    "bbox": MLFeatureValue(multiArray: prepared.bbox),
                    "pixel_values": MLFeatureValue(multiArray: prepared.pixelValues),
                ])
                let output = try await model.prediction(from: provider)
                guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                    throw LayoutLMv3ExtractionError.inferenceFailed("missing logits output")
                }
                return logits
            }.value
        } catch let error as LayoutLMv3ExtractionError {
            throw error
        } catch {
            throw LayoutLMv3ExtractionError.inferenceFailed(error.localizedDescription)
        }

        let predictions = try decoder.decode(logits: logits, tokens: prepared.tokens)
        let grouping = grouper.groupWithTrace(words: words, predictions: predictions)
        return LayoutLMv3ExtractionOutput(
            words: words,
            tokenPredictions: predictions,
            debugExport: LayoutLMv3DebugExport.make(
                prepared: prepared,
                predictions: predictions,
                logits: logits,
                reconstruction: grouping.trace
            ),
            items: grouping.items
        )
    }

    private func resourceURLs() throws -> (
        model: URL,
        tokenizer: URL,
        tokenizerConfig: URL,
        labels: URL
    ) {
        let modelName: String
        let tokenizerName: String
        let tokenizerConfigName: String
        let labelsName: String

        switch version {
        case .v1:
            modelName = "LayoutLMv3_v1"
            tokenizerName = "tokenizer_v1"
            tokenizerConfigName = "tokenizer_config_v1"
            labelsName = "labels_v1"

        case .v2:
            modelName = "LayoutLMv3_v2"
            tokenizerName = "tokenizer_v2"
            tokenizerConfigName = "tokenizer_config_v2"
            labelsName = "labels_v2"
        }

        let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
            ?? Bundle.main.resourceURL?.appendingPathComponent("Models/LayoutLMv3/\(modelName).mlmodelc")
            ?? Bundle.main.url(forResource: modelName, withExtension: "mlpackage")
            ?? Bundle.main.resourceURL?.appendingPathComponent("Models/LayoutLMv3/\(modelName).mlpackage")

        guard let model = modelURL else {
            throw LayoutLMv3ExtractionError.missingModel
        }

        guard let tokenizer = Bundle.main.url(
            forResource: tokenizerName,
            withExtension: "json"
        ) else {
            throw LayoutLMv3ExtractionError.missingTokenizer
        }

        guard let tokenizerConfig = Bundle.main.url(
            forResource: tokenizerConfigName,
            withExtension: "json"
        ) else {
            throw LayoutLMv3ExtractionError.missingTokenizer
        }

        guard let labels = Bundle.main.url(
            forResource: labelsName,
            withExtension: "json"
        ) else {
            throw LayoutLMv3ExtractionError.missingLabels
        }

        return (
            model,
            tokenizer,
            tokenizerConfig,
            labels
        )
    }
}
