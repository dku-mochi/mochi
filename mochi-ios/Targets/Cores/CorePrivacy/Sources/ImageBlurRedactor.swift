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
        // `cacheIntermediates: false` — CoreImage 가 가우시안 중간버퍼를 캐시하지 않게 해 Share Extension
        // 120MB 한도에서 블러 굽기 중 메모리 점유를 낮춘다(굽기는 일회성이라 캐시 이득이 없다).
        self.context = CIContext(options: [.cacheIntermediates: false])
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

        guard let mask = makeMask(width: cgImage.width, height: cgImage.height, normalizedRects: normalizedRects)
        else { return nil }

        // **전체 이미지가 아니라 가릴 영역 합집합 박스만 블러**한다 — `CIBlendWithMask` 가 마스크 밖에선
        // 원본을 쓰므로 전체 가우시안은 낭비고, ShareExt 120MB 한도에서 큰 스크린샷의 풀이미지 가우시안이
        // OOM 의 주범이다. 합집합 박스에 커널 패딩(3σ)을 둬 박스 안 실제 영역의 블러는 정상 이웃 픽셀로
        // 계산되고(가장자리 clamp 영향 구역은 마스크가 검정이라 어차피 원본 노출), 박스를 원본 위에
        // 합성(source-over)해 박스 밖은 원본 그대로 보존한다.
        let region = blurRegion(forNormalized: normalizedRects, in: extent, sigma: sigma)
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }

        let ciMask = CIImage(cgImage: mask)
        let blurredRegion = ciOriginal
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: region)
        let maskedRegion = blurredRegion.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: ciOriginal.cropped(to: region),
            kCIInputMaskImageKey: ciMask.cropped(to: region),
        ])
        let composited = maskedRegion.composited(over: ciOriginal)
        return context.createCGImage(composited, from: extent)
    }

    /// 가릴 영역들의 합집합 픽셀 박스에 **마스크 흰 영역 패딩 + 가우시안 커널 패딩(3σ)** 을 더하고
    /// 이미지 경계로 클램프한다. 마스크 패딩을 그대로 포함하므로 입력 종횡비·해상도와 무관하게
    /// `makeMask` 의 흰 영역 ⊆ region 이 보장된다(패딩 불일치로 마스크가 region 밖으로 새 under-blur 가
    /// 나지 않게 — `redactedImage` 가 비다운샘플로 호출돼도 안전). 이 박스에만 블러를 계산해 작업 메모리를
    /// 영역 크기에 비례시킨다(전체 이미지가 아니라).
    private func blurRegion(forNormalized rects: [CGRect], in extent: CGRect, sigma: Double) -> CGRect {
        let w = extent.width, h = extent.height
        let union = rects.reduce(CGRect.null) { acc, r in
            acc.union(CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h))
        }
        guard !union.isNull else { return .null }
        let mask = Self.maskPadding(width: w, height: h)
        let kernel = CGFloat(sigma) * 3
        return union.insetBy(dx: -(mask.x + kernel), dy: -(mask.y + kernel)).intersection(extent)
    }

    /// `makeMask` 가 각 rect 흰 영역에 더하는 가장자리 패딩. `blurRegion` 이 이 영역을 반드시 포함하도록
    /// 같은 값을 공유한다(두 패딩이 갈라지면 under-blur 누설). 변경 시 한 곳만 고치면 된다.
    private static func maskPadding(width: CGFloat, height: CGFloat) -> (x: CGFloat, y: CGFloat) {
        (width * 0.01, height * 0.004)
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
        // 가장자리 잘림 방지로 약간 패딩 — `blurRegion` 이 이 영역을 포함하도록 같은 값을 공유한다.
        let (padX, padY) = Self.maskPadding(width: w, height: h)
        ctx.setFillColor(gray: 1, alpha: 1)
        for r in normalizedRects {
            let pixelRect = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
                .insetBy(dx: -padX, dy: -padY)
            ctx.fill(pixelRect)
        }
        return ctx.makeImage()
    }
}
