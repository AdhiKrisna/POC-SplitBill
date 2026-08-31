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
                        ResultSection(result: result, image: viewModel.images.indices.contains(index) ? viewModel.images[index] : nil, receiptNumber: index + 1)
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
    let image: UIImage?
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
                if let image {
                    ROIOverlay(image: image, normalizedVisionRect: info.roiUsed ? info.roiRect : nil)
                }
                Text("Detected ROI: \(info.roiRect.map(rectText) ?? "none")")
                Text("ROI confidence = \(info.roiConfidence.value, format: .number.precision(.fractionLength(2))) [\(info.roiConfidence.strategy.rawValue)]")
                Text("ROI used = \(info.roiUsed.description); fallback = \(info.fallback ?? "none")")
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

private struct ROIOverlay: View {
    let image: UIImage
    let normalizedVisionRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay {
                    if let rect = normalizedVisionRect {
                        // Vision is bottom-left origin; SwiftUI is top-left origin.
                        Rectangle()
                            .stroke(.red, lineWidth: 3)
                            .frame(width: rect.width * proxy.size.width, height: rect.height * proxy.size.height)
                            .position(x: (rect.minX + rect.width / 2) * proxy.size.width, y: (1 - rect.minY - rect.height / 2) * proxy.size.height)
                    }
                }
        }
        .aspectRatio(image.size, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Receipt dengan overlay ROI terdeteksi")
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
