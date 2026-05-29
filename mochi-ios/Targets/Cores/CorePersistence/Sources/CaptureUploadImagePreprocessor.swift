import CryptoKit
import Foundation
import UIKit

struct CaptureUploadImage: Sendable, Equatable {
    let data: Data
    let mimeType: String
    let byteSize: Int
    let sha256: String
}

enum CaptureUploadImagePreprocessor {
    static let mimeType = "image/jpeg"

    static func makeUploadVariant(
        from sourceData: Data,
        maxLongEdge: CGFloat = 1920,
        jpegQuality: CGFloat = 0.60
    ) throws -> CaptureUploadImage {
        guard let image = UIImage(data: sourceData) else {
            throw CaptureUploadImagePreprocessorError.decodeFailed
        }
        let resized = resize(image, maxLongEdge: maxLongEdge)
        guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
            throw CaptureUploadImagePreprocessorError.encodeFailed
        }
        return CaptureUploadImage(
            data: data,
            mimeType: mimeType,
            byteSize: data.count,
            sha256: sha256Hex(data)
        )
    }

    private static func resize(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge else { return image }

        let scale = maxLongEdge / longEdge
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CaptureUploadImagePreprocessorError: Error, Sendable, Equatable {
    case decodeFailed
    case encodeFailed
}
