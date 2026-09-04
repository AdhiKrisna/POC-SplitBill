import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()
    @State private var isCameraPresented = false
    @State private var didOfferCamera = false
    @State private var photoItems: [PhotosPickerItem] = []

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    imageSection
                    inputControls
                    experimentControls
                    extractButton
                    statusSection

                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        ResultSection(result: result, originalImage: viewModel.images.indices.contains(index) ? viewModel.images[index] : nil, receiptNumber: index + 1)
                    }
                }
                    .padding()
            }
            .navigationTitle("Scan Struk")
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraPicker { image in
                    viewModel.setImages([image])
                }
            }
            .onAppear {
                guard !didOfferCamera, cameraAvailable else { return }
                didOfferCamera = true
                // The scanner is camera-first; dismissing it still leaves Gallery available.
                DispatchQueue.main.async { isCameraPresented = true }
            }
            .onChange(of: photoItems) { _, items in
                loadImages(from: items)
            }
        }
    }

    private var imageSection: some View {
        Group {
            if let image = viewModel.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Foto struk terpilih")
            } else {
                ContentUnavailableView("Belum ada foto struk", systemImage: "doc.text.viewfinder")
                    .frame(height: 250)
            }
        }
    }

    private var inputControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    isCameraPresented = true
                } label: {
                    Label("Kamera", systemImage: "camera.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cameraAvailable)

                PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .images) {
                    Label("Galeri", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
            }

            if viewModel.images.count > 1 {
                Text("\(viewModel.images.count) foto siap diekstrak")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var extractButton: some View {
        Button {
            viewModel.extract()
        } label: {
            if viewModel.state == .extracting {
                ProgressView("Memindai \(viewModel.completedCount)/\(viewModel.images.count)")
            } else {
                Text(viewModel.images.count > 1 ? "Ekstrak Semua Struk" : "Ekstrak Struk")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.images.isEmpty || viewModel.state == .extracting)
    }

    private var experimentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pipeline eksperimen")
                .font(.subheadline.weight(.semibold))
            Picker("Pipeline eksperimen", selection: $viewModel.extractionMode) {
                ForEach(ExtractionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .disabled(viewModel.state == .extracting)
            Text(modeDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

        }
    }

    private var modeDescription: String {
        if viewModel.extractionMode == .visionLayoutLMv3 {
            return "Vision OCR + Core ML LayoutLMv3 v1 berjalan lokal pada full rectified receipt."
        }

        if viewModel.extractionMode == .visionLayoutLMv3V2 {
            return "Vision OCR + Core ML LayoutLMv3 v2 berjalan lokal pada full rectified receipt."
        }

        if viewModel.extractionMode == .layoutLMv3 {
            return "LayoutLMv3 export memakai full rectified receipt. Transaction ROI dilewati sepenuhnya."
        }

        if viewModel.extractionMode == .fastVLM {
            return "FastVLM eksperimental: on-device VLM memakai full rectified receipt plus OCR mentah sebagai grounding."
        }

        return viewModel.extractionMode.usesROI
            ? "Legacy transaction ROI aktif; fallback ke full receipt jika confidence rendah."
            : "Seluruh receipt diproses tanpa transaction ROI."
    }
    @ViewBuilder
    private var statusSection: some View {
        if case .failed(let message) = viewModel.state {
            Text(message)
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }

    private func loadImages(from items: [PhotosPickerItem]) {
        Task {
            var images: [UIImage] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { continue }
                images.append(image)
            }
            viewModel.setImages(images)
        }
    }


}

private struct ResultSection: View {
    let result: ExtractionResult
    let originalImage: UIImage?
    let receiptNumber: Int
    @State private var exportFiles: [URL] = []
    @State private var exportError: String?
    @State private var isSharePresented = false

    private var summary: ReceiptSummary { result.summary }
    private var emptyItemMessage: String {
        guard let trace = result.layoutLMv3DebugExport?.reconstruction else {
            return "Format item belum dikenali. Teks OCR tetap tersedia di bawah."
        }
        return "LayoutLMv3 \(trace.status.rawValue): \(trace.nonOWordCount) kata non-O, "
            + "\(trace.entityCounts["ITEM", default: 0]) entitas ITEM, "
            + "0 ReceiptItem. Buka trace untuk detail."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if receiptNumber > 1 {
                Text("Struk \(receiptNumber)")
                    .font(.headline)
            }
            if summary.items.isEmpty {
                Label(emptyItemMessage, systemImage: "text.viewfinder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.items) { item in
                    ItemRow(item: item)
                    Divider()
                }
            }

            receiptMetadataSection
            warningsSection

            if shouldShowTotals {
                totalsBlock
            }

            if !summary.rawText.isEmpty {
                DisclosureGroup("Teks OCR mentah") {
                    Text(summary.rawText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .tint(.secondary)
            }

            layoutLMv3PredictionSection

            diagnostics
            visionOCRJSONSection
            exportSection
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $isSharePresented) {
            ActivityView(items: exportFiles)
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        let info = result.diagnostics
        let isLayoutLMv3 = info.extractionMode.usesLayoutLMv3
        DisclosureGroup("Debug pipeline") {
            VStack(alignment: .leading, spacing: 8) {
                if let originalImage {
                    Text("Original receipt")
                        .fontWeight(.semibold)
                    DebugImageOverlay(image: originalImage, quadrilateral: info.documentQuadrilateral, normalizedVisionRect: !isLayoutLMv3 && result.preprocessedImage == nil && info.roiUsed ? info.roiRect : nil)
                }
                if let preprocessedImage = result.preprocessedImage {
                    Text(info.rectifiedImageSize != nil ? "Rectified receipt" : "Document-localized receipt")
                        .fontWeight(.semibold)
                    DebugImageOverlay(image: preprocessedImage, quadrilateral: nil, normalizedVisionRect: !isLayoutLMv3 && info.roiUsed ? info.roiRect : nil)
                }
                Text(isLayoutLMv3 || !info.roiUsed ? "OCR input scope: full rectified receipt" : "OCR input scope: transaction ROI crop")
                    .fontWeight(.semibold)
                DebugImageOverlay(
                    image: result.ocrImage,
                    quadrilateral: nil,
                    normalizedVisionRect: nil
                )
                Text("LayoutLMv3 document scope = \(result.layoutLMv3DocumentScope.rawValue)")
                Text("Document preprocessing = segmentation + perspective rectification")
                Text("Document detected = \(info.documentDetected.description); confidence = \(info.documentConfidence, format: .number.precision(.fractionLength(2)))")
                Text("Document quadrilateral = \(info.documentQuadrilateral.map(quadrilateralText) ?? "none")")
                Text("Document fallback = \(info.documentFallback ?? "none"); rectified size = \(info.rectifiedImageSize.map(sizeText) ?? "none")")
                if !isLayoutLMv3 && info.requestedROI {
                    Text("Legacy transaction ROI: \(info.roiRect.map(rectText) ?? "none")")
                    Text("Legacy ROI confidence = \(info.roiConfidence.value, format: .number.precision(.fractionLength(2))) [\(info.roiConfidence.strategy.rawValue)]")
                    Text("Legacy ROI used = \(info.roiUsed.description); fallback = \(info.roiFallback ?? "none")")
                } else if isLayoutLMv3 {
                    Text("LayoutLMv3 transaction ROI = bypassed")
                } else {
                    Text("Legacy transaction ROI = not requested")
                }
                Text("Extraction mode = \(info.extractionMode.rawValue)")
                Text("Full-document OCR observations = \(info.layoutObservationCount); native OCR observations = \(info.ocrObservationCount)")
                debugText("Foundation input", info.foundationInput)
                debugText("Foundation output", info.foundationOutput)
                debugText("FastVLM output", info.fastVLMOutput)
                if let rawModelOutput = summary.rawModelOutput,
                   !rawModelOutput.isEmpty,
                   rawModelOutput != info.foundationOutput,
                   rawModelOutput != info.fastVLMOutput {
                    debugText("Raw model output", rawModelOutput)
                }
                if !visionOCRJSON.isEmpty {
                    debugText("Vision OCR JSON", visionOCRJSON)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.top, 4)
        }
        .tint(.secondary)
    }

    @ViewBuilder
    private var layoutLMv3PredictionSection: some View {
        if let debug = result.layoutLMv3DebugExport {
            DisclosureGroup("Trace OCR word LayoutLMv3") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: reconstructionSummary(debug.reconstruction))
                        .fontWeight(.semibold)
                        .padding(.bottom, 4)
                    ForEach(debug.words, id: \.index) { word in
                        Text(verbatim: "WORD[\(word.index)] \(word.text) bbox=\(word.normalizedBBox)")
                            .fontWeight(.semibold)
                        ForEach(debug.tokens.filter { $0.wordIndex == word.index }, id: \.index) { token in
                            Text(
                                "  \(token.token) id=\(token.tokenID) bbox=\(token.bbox) "
                                + "\(token.predictedLabel ?? "?") "
                                + String(format: "%.3f", token.confidence ?? 0)
                            )
                        }
                    }
                    Text("WORD-LEVEL AGGREGATION")
                        .fontWeight(.semibold)
                        .padding(.top, 6)
                    ForEach(debug.reconstruction.wordPredictions, id: \.wordIndex) { prediction in
                        Text(verbatim:
                            "WORD[\(prediction.wordIndex)] \(prediction.text) -> "
                            + "\(prediction.label) \(String(format: "%.3f", prediction.confidence)) "
                            + "firstToken=\(prediction.sourceTokenIndex) "
                            + "subwords=\(prediction.subwordTokenIndices)"
                        )
                    }
                    Text("BIO ENTITIES")
                        .fontWeight(.semibold)
                        .padding(.top, 6)
                    ForEach(Array(debug.reconstruction.entities.enumerated()), id: \.offset) { _, entity in
                        Text(verbatim: "\(entity.type): \(entity.text) bbox=\(entity.bbox)")
                    }
                    Text("RECONSTRUCTED RECEIPT ITEMS")
                        .fontWeight(.semibold)
                        .padding(.top, 6)
                    ForEach(Array(debug.reconstruction.items.enumerated()), id: \.offset) { _, item in
                        Text(verbatim:
                            "\(item.name) qty=\(item.quantity) unit=\(item.unitPrice) "
                            + "line=\(item.lineTotal) rows=\([item.itemRowIndex] + item.attachedNumericRowIndices)"
                        )
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .tint(.secondary)
        }
    }

    @ViewBuilder
    private var visionOCRJSONSection: some View {
        if !visionOCRJSON.isEmpty {
            DisclosureGroup("Vision OCR JSON") {
                Text(visionOCRJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .tint(.secondary)
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                exportLayoutLMv3Bundle()
            } label: {
                Label("Export LayoutLMv3 PNG + JSON", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)

            if result.layoutLMv3DebugExport != nil {
                Button {
                    exportLayoutLMv3Debug()
                } label: {
                    Label("Export LayoutLMv3 Debug JSON", systemImage: "ladybug")
                }
                .buttonStyle(.bordered)
            }

            Text("LayoutLMv3 export uses the full rectified receipt and full-document OCR boxes. Legacy transaction ROI is excluded.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let exportError {
                Text(exportError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func rectText(_ rect: CGRect) -> String {
        String(format: "x=%.3f, y=%.3f, width=%.3f, height=%.3f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private func quadrilateralText(_ quadrilateral: DocumentQuadrilateral) -> String {
        "TL(\(pointText(quadrilateral.topLeft))) TR(\(pointText(quadrilateral.topRight))) BR(\(pointText(quadrilateral.bottomRight))) BL(\(pointText(quadrilateral.bottomLeft)))"
    }

    private func pointText(_ point: CGPoint) -> String {
        String(format: "%.3f,%.3f", point.x, point.y)
    }

    private func sizeText(_ size: CGSize) -> String {
        String(format: "%.0f×%.0f", size.width, size.height)
    }

    private func reconstructionSummary(_ trace: LayoutLMv3ReconstructionTrace) -> String {
        let counts = ["ITEM", "QTY", "UNIT_PRICE", "LINE_TOTAL"].map {
            "\($0): \(trace.entityCounts[$0, default: 0])"
        }.joined(separator: "\n")
        return """
        LayoutLMv3:
        OCR words: \(trace.ocrWordCount)
        predicted words: \(trace.predictedWordCount)
        non-O predicted words: \(trace.nonOWordCount)
        \(counts)
        reconstructed items: \(trace.reconstructedItemCount)
        status: \(trace.status.rawValue)
        """
    }

    private func debugText(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title):")
                .fontWeight(.semibold)
            Text(value.isEmpty ? "(empty)" : value)
        }
    }

    @ViewBuilder
    private var receiptMetadataSection: some View {
        if summary.storeName != nil
            || summary.transactionDate != nil
            || summary.transactionTime != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let storeName = summary.storeName {
                    Text(storeName)
                        .font(.subheadline.weight(.semibold))
                }
                if let transactionDate = summary.transactionDate {
                    Text("Tanggal: \(transactionDate)")
                }
                if let transactionTime = summary.transactionTime {
                    Text("Jam: \(transactionTime)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        if !summary.warnings.isEmpty {
            DisclosureGroup("Warnings") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.warnings, id: \.self) { warning in
                        Text(warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.top, 4)
            }
            .tint(.secondary)
        }
    }

    private var shouldShowTotals: Bool {
        !summary.items.isEmpty
            || summary.subtotalAmount != nil
            || summary.taxAmount != nil
            || summary.serviceChargeAmount != nil
            || summary.discountTotalAmount != nil
            || summary.grandTotalAmount != nil
    }

    private var totalsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Total sebelum diskon", summary.totalBeforeDiscount)
            row("Total diskon", -summary.totalDiscount)
            if let taxAmount = summary.taxAmount {
                row("Pajak", taxAmount)
            }
            if let serviceChargeAmount = summary.serviceChargeAmount {
                row("Service charge", serviceChargeAmount)
            }
            row("Total setelah diskon", summary.totalAfterDiscount, bold: true)
            if summary.grandTotalAmount != nil || summary.totalTaxAndService > 0 {
                row("Grand total", summary.finalPayableTotal, bold: true)
            }
        }
    }

    private func row(_ label: String, _ value: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value, format: .currency(code: "IDR"))
        }
        .font(bold ? .headline : .subheadline)
    }

    private var visionOCRJSON: String {
        guard let data = try? VisionOCRExporter.makeJSON(
                  image: result.layoutLMv3Image,
                  imageFilename: "receipt_\(receiptNumber).png",
                  observations: result.layoutLMv3Observations,
                  documentScope: result.layoutLMv3DocumentScope
              ),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }

        return json
    }

    private func exportLayoutLMv3Bundle() {
        do {
            let bundle = try VisionOCRExporter.exportBundle(
                image: result.layoutLMv3Image,
                stem: "receipt_\(receiptNumber)",
                observations: result.layoutLMv3Observations,
                documentScope: result.layoutLMv3DocumentScope
            )
            exportFiles = bundle.files
            exportError = nil
            isSharePresented = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportLayoutLMv3Debug() {
        do {
            guard let debug = result.layoutLMv3DebugExport else { return }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LayoutLMv3Debug", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let jsonURL = directory.appendingPathComponent("layoutlmv3_debug_export.json")
            try debug.encoded().write(to: jsonURL, options: .atomic)
            var files = [jsonURL]
            if let imageData = result.layoutLMv3Image.pngData() {
                let imageURL = directory.appendingPathComponent("layoutlmv3_debug_receipt.png")
                try imageData.write(to: imageURL, options: .atomic)
                files.append(imageURL)
            }
            exportFiles = files
            exportError = nil
            isSharePresented = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct DebugImageOverlay: View {
    let image: UIImage
    let quadrilateral: DocumentQuadrilateral?
    let normalizedVisionRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                if let quadrilateral {
                    quadrilateralPath(quadrilateral, in: fitted)
                        .stroke(.blue, lineWidth: 3)
                }
                if let rect = normalizedVisionRect {
                    Rectangle()
                        .stroke(.red, lineWidth: 3)
                        .frame(width: rect.width * fitted.width, height: rect.height * fitted.height)
                        .position(x: fitted.minX + (rect.minX + rect.width / 2) * fitted.width, y: fitted.minY + (1 - rect.minY - rect.height / 2) * fitted.height)
                }
            }
        }
        .aspectRatio(image.size, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Receipt debug overlay")
    }

    private func fittedRect(in available: CGSize) -> CGRect {
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func quadrilateralPath(_ quadrilateral: DocumentQuadrilateral, in rect: CGRect) -> Path {
        func point(_ source: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + source.x * rect.width, y: rect.minY + (1 - source.y) * rect.height)
        }
        var path = Path()
        path.move(to: point(quadrilateral.topLeft))
        path.addLine(to: point(quadrilateral.topRight))
        path.addLine(to: point(quadrilateral.bottomRight))
        path.addLine(to: point(quadrilateral.bottomLeft))
        path.closeSubpath()
        return path
    }
}

private struct ItemRow: View {
    let item: ReceiptItem

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(item.name)
                Text("\(item.quantity) x \(item.unitPrice, format: .currency(code: "IDR"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(item.totalAfterDiscount, format: .currency(code: "IDR"))
                if item.hasDiscount {
                    Text("- \(item.discountAmount, format: .currency(code: "IDR"))")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }
}
