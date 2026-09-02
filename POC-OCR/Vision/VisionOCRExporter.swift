import CryptoKit
import Foundation
import UIKit

struct VisionOCRExportWord: Encodable {
    let text: String
    let bbox: [Int]
    let confidence: Float
}

enum VisionOCRDocumentScope: String, Encodable {
    case fullRectifiedDocument = "full_rectified_document"
    case fullDocumentUnrectified = "full_document_unrectified"
}

struct VisionOCRExportDocument: Encodable {
    let schemaVersion: Int
    let imagePath: String
    let imageWidth: Int
    let imageHeight: Int
    let imageSHA256: String
    let coordinateSpace: String
    let observationGranularity: String
    let documentScope: VisionOCRDocumentScope
    let transactionROIBBox: [Int]?
    let words: [VisionOCRExportWord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case imagePath = "image_path"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case imageSHA256 = "image_sha256"
        case coordinateSpace = "coordinate_space"
        case observationGranularity = "observation_granularity"
        case documentScope = "document_scope"
        case transactionROIBBox = "transaction_roi_bbox"
        case words
    }
}

struct VisionOCRExportBundle {
    let imageURL: URL
    let jsonURL: URL

    var files: [URL] { [imageURL, jsonURL] }
}

enum VisionOCRExporter {
    static func makeJSON(
        image: UIImage,
        imageFilename: String,
        observations: [VisionTextObservation],
        documentScope: VisionOCRDocumentScope,
        transactionROIRect: CGRect? = nil,
        imageData: Data? = nil
    ) throws -> Data {
        let exportImage = uprightImage(image)
        guard let cgImage = exportImage.cgImage,
              let pngData = imageData ?? exportImage.pngData() else {
            throw VisionOCRExportError.cannotEncodeImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let hasLineFallback = observations.contains { $0.words.isEmpty }
        let words = observations.flatMap { observation -> [VisionOCRExportWord] in
            if observation.words.isEmpty {
                return [exportWord(
                    text: observation.text,
                    boundingBox: observation.boundingBox,
                    confidence: observation.confidence,
                    width: width,
                    height: height
                )]
            }

            return observation.words.map { word in
                exportWord(
                    text: word.text,
                    boundingBox: word.boundingBox,
                    confidence: word.confidence,
                    width: width,
                    height: height
                )
            }
        }

        let document = VisionOCRExportDocument(
            schemaVersion: 3,
            imagePath: imageFilename,
            imageWidth: width,
            imageHeight: height,
            imageSHA256: SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined(),
            coordinateSpace: "ocr_image_pixels_top_left",
            observationGranularity: hasLineFallback ? "mixed_word_and_line_fallback" : "word",
            documentScope: documentScope,
            transactionROIBBox: transactionROIRect.map {
                pixelBBox(
                    fromNormalizedVisionRect: $0,
                    width: width,
                    height: height
                )
            },
            words: words
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func exportBundle(
        image: UIImage,
        stem: String,
        observations: [VisionTextObservation],
        documentScope: VisionOCRDocumentScope,
        transactionROIRect: CGRect? = nil
    ) throws -> VisionOCRExportBundle {
        guard documentScope == .fullRectifiedDocument else {
            throw VisionOCRExportError.requiresFullRectifiedDocument
        }

        let exportImage = uprightImage(image)
        guard let pngData = exportImage.pngData() else {
            throw VisionOCRExportError.cannotEncodeImage
        }

        let safeStem = sanitizedStem(stem)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutLMv3Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let imageURL = directory.appendingPathComponent("\(safeStem).png")
        let jsonURL = directory.appendingPathComponent("\(safeStem).json")
        let jsonData = try makeJSON(
            image: exportImage,
            imageFilename: imageURL.lastPathComponent,
            observations: observations,
            documentScope: documentScope,
            transactionROIRect: transactionROIRect,
            imageData: pngData
        )

        try pngData.write(to: imageURL, options: .atomic)
        try jsonData.write(to: jsonURL, options: .atomic)
        return VisionOCRExportBundle(imageURL: imageURL, jsonURL: jsonURL)
    }

    private static func exportWord(
        text: String,
        boundingBox box: CGRect,
        confidence: Float,
        width: Int,
        height: Int
    ) -> VisionOCRExportWord {
        let x1 = max(0, min(width, Int((box.minX * CGFloat(width)).rounded(.down))))
        let y1 = max(0, min(height, Int(((1 - box.maxY) * CGFloat(height)).rounded(.down))))
        let x2 = max(0, min(width, Int((box.maxX * CGFloat(width)).rounded(.up))))
        let y2 = max(0, min(height, Int(((1 - box.minY) * CGFloat(height)).rounded(.up))))

        return VisionOCRExportWord(
            text: text,
            bbox: [x1, y1, x2, y2],
            confidence: confidence
        )
    }

    private static func pixelBBox(
        fromNormalizedVisionRect box: CGRect,
        width: Int,
        height: Int
    ) -> [Int] {
        let x1 = max(0, min(width, Int((box.minX * CGFloat(width)).rounded(.down))))
        let y1 = max(0, min(height, Int(((1 - box.maxY) * CGFloat(height)).rounded(.down))))
        let x2 = max(0, min(width, Int((box.maxX * CGFloat(width)).rounded(.up))))
        let y2 = max(0, min(height, Int(((1 - box.minY) * CGFloat(height)).rounded(.up))))
        return [x1, y1, x2, y2]
    }

    private static func uprightImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func sanitizedStem(_ stem: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = stem.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(value)
        return result.isEmpty ? "receipt" : result
    }
}

private enum VisionOCRExportError: LocalizedError {
    case cannotEncodeImage
    case requiresFullRectifiedDocument

    var errorDescription: String? {
        switch self {
        case .cannotEncodeImage:
            "The OCR image could not be encoded as PNG."
        case .requiresFullRectifiedDocument:
            "LayoutLMv3 P0 export requires successful document segmentation and rectification."
        }
    }
}
