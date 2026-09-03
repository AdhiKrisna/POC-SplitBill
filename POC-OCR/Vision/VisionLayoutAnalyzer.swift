import UIKit
import Vision

final class VisionLayoutAnalyzer {
    /// Legacy-only structural pass. LayoutLMv3 uses the regular full-document
    /// OCR observations directly and must not invoke RecognizeDocumentsRequest.
    func analyzeLegacyROI(
        image: UIImage,
        observations: [VisionTextObservation]
    ) async -> VisionDocumentLayout {
        let tables = (try? await recognizeTables(in: image)) ?? []

        return VisionDocumentLayout(
            observations: observations,
            tables: tables
        )
    }

    private func recognizeTables(in image: UIImage) async throws -> [VisionTableObservation] {
        guard let data = image.jpegData(compressionQuality: 1) else {
            return []
        }

        let request = RecognizeDocumentsRequest()
        let documents = try await request.perform(on: data)

        return documents.flatMap { observation in
            observation.document.tables.map { table in
                let rows = table.rows.map { row in
                    let cells = row.map { cell in
                        VisionTableCellObservation(
                            text: cell.content.text.transcript,
                            boundingBox: cell.content.boundingRegion.boundingBox.cgRect
                        )
                    }

                    let rowBox = cells.reduce(CGRect.null) {
                        $0.union($1.boundingBox)
                    }

                    return VisionTableRowObservation(
                        boundingBox: rowBox,
                        cells: cells
                    )
                }

                return VisionTableObservation(
                    boundingBox: table.boundingRegion.boundingBox.cgRect,
                    rows: rows
                )
            }
        }
    }
}
