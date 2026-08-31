import CoreImage
import UIKit

enum DocumentRectifierError: LocalizedError {
    case noImage
    case correctionFailed

    var errorDescription: String? {
        switch self {
        case .noImage: "Image cannot be rectified."
        case .correctionFailed: "Perspective correction failed."
        }
    }
}

final class DocumentRectifier {
    private let context = CIContext()

    func rectify(image: UIImage, quadrilateral: DocumentQuadrilateral) throws -> UIImage {
        let upright = image.uprightImage()
        guard let cgImage = upright.cgImage else { throw DocumentRectifierError.noImage }
        let source = CIImage(cgImage: cgImage)
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { throw DocumentRectifierError.correctionFailed }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: pixelPoint(quadrilateral.topLeft, imageSize: size)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: pixelPoint(quadrilateral.topRight, imageSize: size)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: pixelPoint(quadrilateral.bottomRight, imageSize: size)), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: pixelPoint(quadrilateral.bottomLeft, imageSize: size)), forKey: "inputBottomLeft")
        guard let output = filter.outputImage,
              let corrected = context.createCGImage(output, from: output.extent) else { throw DocumentRectifierError.correctionFailed }
        return UIImage(cgImage: corrected, scale: upright.scale, orientation: .up)
    }

    private func pixelPoint(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
    }
}

private extension UIImage {
    func uprightImage() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
