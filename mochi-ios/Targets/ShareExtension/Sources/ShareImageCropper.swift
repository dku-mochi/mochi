import UIKit
import CryptoKit
import CoreDomain
import CorePersistence

/// App Group 에 저장된 캡처 이미지에 **사용자 크롭**(``ShareCropImage`` 가 만든 정규화 rect)을 적용해
/// 새 파일 + 새 ``ImageRef`` 를 만든다. 백엔드 계약(이미지 1장 = 1 ImageRef)은 그대로라, 크롭은
/// 익스텐션 안에서 끝나고 서버는 "이미 잘린 이미지"만 받는다.
///
/// 호출부(``ShareExtensionPrincipal.persist``)는 반환된 새 ref 로 payload 의 imageRefs[0] 을 교체하고,
/// 기존 고아청소 로직(`original` 에 있지만 payload 에 없는 ref 삭제)이 원본 파일을 자동 정리한다.
enum ShareImageCropper {
    /// crop: 0...1 정규화 rect, **표시 이미지(orientation 적용) 기준**. 사실상 전체면(epsilon 여백)
    /// nil 을 돌려 호출부가 원본을 그대로 쓰게 한다(불필요한 재인코딩 회피).
    static func croppedRef(from ref: ImageRef, crop: CGRect) -> ImageRef? {
        guard !isFull(crop) else { return nil }

        let srcURL = AppGroup.containerURL.appendingPathComponent(ref.relativePath)
        guard let data = try? Data(contentsOf: srcURL),
              let image = UIImage(data: data),
              let cg = orientedCGImage(image) else { return nil }

        let pixelW = CGFloat(cg.width)
        let pixelH = CGFloat(cg.height)
        let rect = CGRect(
            x: (crop.minX * pixelW).rounded(.down),
            y: (crop.minY * pixelH).rounded(.down),
            width: (crop.width * pixelW).rounded(),
            height: (crop.height * pixelH).rounded()
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

        guard rect.width >= 1, rect.height >= 1,
              let cropped = cg.cropping(to: rect) else { return nil }

        let croppedImage = UIImage(cgImage: cropped)
        // 원본이 jpeg 면 jpeg(0.92 면 텍스트 많은 스크린샷도 충분), 그 외엔 png 무손실.
        let isJPEG = ref.mimeType.localizedCaseInsensitiveContains("jpeg")
            || ref.mimeType.localizedCaseInsensitiveContains("jpg")
        let outData: Data?
        let ext: String
        let mime: String
        if isJPEG {
            outData = croppedImage.jpegData(compressionQuality: 0.92)
            ext = "jpg"
            mime = "image/jpeg"
        } else {
            outData = croppedImage.pngData()
            ext = "png"
            mime = "image/png"
        }
        guard let bytes = outData else { return nil }

        let filename = "\(UUID().uuidString).\(ext)"
        let relativePath = "captures/\(filename)"
        let destination = AppGroup.capturedImagesDirectoryURL.appendingPathComponent(filename)
        guard (try? bytes.write(to: destination, options: [.atomic])) != nil else { return nil }

        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ImageRef(
            relativePath: relativePath,
            mimeType: mime,
            byteSize: bytes.count,
            sha256: digest,
            objectKey: nil
        )
    }

    /// crop 이 사실상 전체(여백 epsilon 이내)인지 — 크롭 안 했거나 무시할 만한 미세 조정.
    static func isFull(_ rect: CGRect) -> Bool {
        let e: CGFloat = 0.004
        return rect.minX <= e && rect.minY <= e && rect.maxX >= 1 - e && rect.maxY >= 1 - e
    }

    /// orientation 을 .up 으로 베이크한다 — 정규화 crop 이 **표시(oriented) 좌표** 기준이라
    /// raw `cgImage` 의 픽셀 좌표와 어긋나지 않게 한다. 스크린샷은 대부분 `.up` 이라 redraw 가
    /// 거의 트리거되지 않는다(외부 공유 사진만 해당).
    private static func orientedCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return redrawn.cgImage
    }
}
