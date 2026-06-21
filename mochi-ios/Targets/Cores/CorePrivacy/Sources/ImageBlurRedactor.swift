import CoreGraphics
import CoreImage
import Foundation

/// 감지된 민감 영역만 가우시안 블러로 가린 파생 이미지를 만든다.
///
/// 전체를 블러한 버전과 원본을, "민감 영역만 흰색" 마스크로 `CIBlendWithMask` 합성한다.
/// 블러는 강하게 건다 — 약한 블러는 deblur/재-OCR 위험이 있으므로 복원 불가 수준으로 가린다.
public struct ImageBlurRedactor {
    private let context: CIContext

    public init() {
        self.context = CIContext(options: nil)
    }

    /// - Parameters:
    ///   - cgImage: 원본 이미지.
    ///   - normalizedRects: 블러할 영역(Vision 정규화 좌표, 원점 좌하단, 0–1).
    /// - Returns: 블러본 `CGImage`. 블러할 영역이 없으면 `nil`.
    public func redactedImage(from cgImage: CGImage, normalizedRects: [CGRect]) -> CGImage? {
        guard !normalizedRects.isEmpty else { return nil }
        let ciOriginal = CIImage(cgImage: cgImage)
        let extent = ciOriginal.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        // 약한 블러는 deblur/재-OCR 로 복원될 수 있다(정본 §9 "강하게"). 짧은 변의 1/30(최소 16)의
        // 큰 sigma 로 복원 불가 수준까지 뭉갠다. 마스크가 영역을 제한하므로 주변은 보존된다.
        let sigma = Double(max(16, Int(min(extent.width, extent.height) / 30)))
        let blurred = ciOriginal
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)

        guard let mask = makeMask(width: cgImage.width, height: cgImage.height, normalizedRects: normalizedRects)
        else { return nil }

        let blended = blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: ciOriginal,
            kCIInputMaskImageKey: CIImage(cgImage: mask),
        ])
        return context.createCGImage(blended, from: extent)
    }

    /// 검정 배경 + 민감 영역만 흰색인 그레이스케일 마스크. CG·Vision 모두 원점 좌하단이라 y 변환 불필요.
    private func makeMask(width: Int, height: Int, normalizedRects: [CGRect]) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let w = CGFloat(width), h = CGFloat(height)
        // 가장자리 잘림 방지로 약간 패딩.
        let padX = w * 0.01, padY = h * 0.004
        ctx.setFillColor(gray: 1, alpha: 1)
        for r in normalizedRects {
            let pixelRect = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
                .insetBy(dx: -padX, dy: -padY)
            ctx.fill(pixelRect)
        }
        return ctx.makeImage()
    }
}
