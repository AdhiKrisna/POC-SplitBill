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
            Text("Mode eksperimen")
                .font(.subheadline.weight(.semibold))
            Picker("Mode eksperimen", selection: $viewModel.extractionMode) {
                ForEach(ExtractionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text(viewModel.extractionMode.usesROI ? "ROI dinamis aktif; fallback ke full receipt jika confidence rendah." : "Seluruh receipt diproses.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Document preprocessing")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            Picker("Document preprocessing", selection: $viewModel.preprocessingMode) {
                ForEach(DocumentPreprocessingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("Segmentasi melokalisasi receipt; rectification menguji normalisasi perspektif sebelum ROI yang sama dijalankan.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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

    private var summary: ReceiptSummary { result.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if receiptNumber > 1 {
                Text("Struk \(receiptNumber)")
                    .font(.headline)
            }
            if summary.items.isEmpty {
                Label("Format item belum dikenali. Teks OCR tetap tersedia di bawah.", systemImage: "text.viewfinder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.items) { item in
                    ItemRow(item: item)
                    Divider()
                }
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

            diagnostics
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var diagnostics: some View {
        let info = result.diagnostics
        DisclosureGroup("Debug pipeline") {
            VStack(alignment: .leading, spacing: 8) {
                if let originalImage {
                    Text("Original receipt")
                        .fontWeight(.semibold)
                    DebugImageOverlay(image: originalImage, quadrilateral: info.documentQuadrilateral, normalizedVisionRect: result.preprocessedImage == nil && info.roiUsed ? info.roiRect : nil)
                }
                if let preprocessedImage = result.preprocessedImage {
                    Text(info.preprocessingMode == .documentSegmentationAndRectification && info.rectifiedImageSize != nil ? "Rectified receipt" : "Document-localized receipt")
                        .fontWeight(.semibold)
                    DebugImageOverlay(image: preprocessedImage, quadrilateral: nil, normalizedVisionRect: info.roiUsed ? info.roiRect : nil)
                }
                Text("Preprocessing = \(info.preprocessingMode.rawValue)")
                Text("Document detected = \(info.documentDetected.description); confidence = \(info.documentConfidence, format: .number.precision(.fractionLength(2)))")
                Text("Document quadrilateral = \(info.documentQuadrilateral.map(quadrilateralText) ?? "none")")
                Text("Document fallback = \(info.documentFallback ?? "none"); rectified size = \(info.rectifiedImageSize.map(sizeText) ?? "none")")
                Text("Detected ROI: \(info.roiRect.map(rectText) ?? "none")")
                Text("ROI confidence = \(info.roiConfidence.value, format: .number.precision(.fractionLength(2))) [\(info.roiConfidence.strategy.rawValue)]")
                Text("ROI used = \(info.roiUsed.description); fallback = \(info.roiFallback ?? "none")")
                Text("Extraction mode = \(info.extractionMode.rawValue)")
                Text("Vision observations = layout: \(info.layoutObservationCount), OCR: \(info.ocrObservationCount)")
                debugText("Foundation input", info.foundationInput)
                debugText("Foundation output", info.foundationOutput)
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.top, 4)
        }
        .tint(.secondary)
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

    private func debugText(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title):")
                .fontWeight(.semibold)
            Text(value.isEmpty ? "(empty)" : value)
        }
    }

    private var totalsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Total sebelum diskon", summary.totalBeforeDiscount)
            row("Total diskon", -summary.totalDiscount)
            row("Total setelah diskon", summary.totalAfterDiscount, bold: true)
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
        .accessibilityLabel("Receipt dengan overlay ROI terdeteksi")
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
