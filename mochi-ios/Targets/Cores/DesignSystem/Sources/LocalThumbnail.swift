import SwiftUI
import UIKit
import ImageIO
import CorePersistence

/// App Group 컨테이너에 저장된 캡처(스크린샷) 이미지를 비동기로 로드·다운샘플해 표시한다.
///
/// 홈/상세의 카드는 여러 셀이 동시에 보이므로, full-res 스크린샷을 메인 스레드에서
/// 동기 디코드하면 스크롤이 끊긴다. ImageIO 썸네일 API 로 셀 크기에 맞춰 다운샘플하고
/// `Task.detached` 로 디코드를 메인 밖으로 뺀다. 경로가 nil 이거나 로드 실패 시 `placeholder` 폴백.
///
/// 같은 디스크 read 패턴은 Live Activity 의 `ThumbnailColumn` / ShareExtension 의
/// `SharePreviewImage` 에도 있다 (App Group container + `ImageRef.relativePath`).
public struct LocalThumbnail<Placeholder: View>: View {
    let relativePath: String?
    let targetSize: CGSize
    /// `.fill` 로 채운 이미지가 프레임을 넘칠 때 어느 쪽을 보여줄지. 스크린샷(세로 비율)은
    /// `.top` 으로 상단(상태바·제목)을 보여주는 게 알아보기 쉽다. 기본 `.center`.
    var alignment: Alignment = .center
    /// `targetSize` 비율로 center aspect-fill 했을 때 *보이는* 영역 하단 35% 의 평균 휘도
    /// (0=검정, 1=흰색)를 로드 직후 알려준다. 이미지 위에 글씨를 얹는 호출부가 스크림 강도를
    /// 정하는 용도 — nil 이면 계산 자체를 생략. `alignment: .center` 전제의 근사 휴리스틱이다
    /// (가로 이미지의 fit+blur 분기에선 비트맵 하단 기준으로 어긋나지만 클램프된 용도라 감수).
    var onBottomLuminance: ((CGFloat) -> Void)?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    public init(
        relativePath: String?,
        targetSize: CGSize,
        alignment: Alignment = .center,
        onBottomLuminance: ((CGFloat) -> Void)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.relativePath = relativePath
        self.targetSize = targetSize
        self.alignment = alignment
        self.onBottomLuminance = onBottomLuminance
        self.placeholder = placeholder
    }

    public var body: some View {
        GeometryReader { geo in
            content(geo.size)
        }
        .task(id: relativePath) {
            // @3x 까지 커버하도록 셀 변 길이의 3배를 상한 픽셀로 둔다.
            let maxPixel = Int(max(targetSize.width, targetSize.height) * 3)
            let loaded = await loadDownsampledContainerImage(
                relativePath: relativePath,
                maxPixel: maxPixel,
                visibleAspectForLuminance: onBottomLuminance != nil && targetSize.height > 0
                    ? targetSize.width / targetSize.height
                    : nil
            )
            // detached task 는 취소돼도 끝까지 돌므로, 셀 재사용으로 task 가 바뀐 뒤의 stale 결과를 버린다.
            guard !Task.isCancelled else { return }
            image = loaded?.image
            if let luminance = loaded?.bottomLuminance { onBottomLuminance?(luminance) }
        }
    }

    /// 이미지 orientation 에 따라 렌더 방식을 자동 분기한다 (표시 크기는 호출부 프레임 = 2:1 세로 고정).
    /// 각 이미지에 명시 `frame(size)` + `clipped()` 를 걸어 `.scaledToFill` 오버플로가 박스 밖으로
    /// 새지 않게 한다 (호출부 레이아웃 침범 방지).
    /// - 세로(portrait, h>=w): `.scaledToFill` + `alignment` 크롭 — 위아래가 조금 잘려도 화면(세로 캡처)을 크게.
    /// - 가로(landscape, w>h): `.scaledToFit` + 같은 이미지 블러 확대본 배경 — 잘림 없이 전체를 보여주고 레터박스를 채운다.
    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        if let image {
            if image.size.width > image.size.height {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 12)
                        .clipped()
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height, alignment: alignment)
                    .clipped()
            }
        } else {
            placeholder()
                .frame(width: size.width, height: size.height)
        }
    }
}

/// App Group 컨테이너의 캡처를 **동기**로 다운샘플 로드한다 (배지·테두리 없는 순수 스크린샷).
/// hero 전환처럼 탭 직후 한 장만 즉시 필요한 경우용 — 여러 셀 동시 로드는 `LocalThumbnail`(비동기) 사용.
public func loadContainerThumbnailSync(relativePath: String?, maxPixel: Int) -> UIImage? {
    guard let relativePath else { return nil }
    let url = AppGroup.containerURL.appendingPathComponent(relativePath)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}

/// 갓 만든 immutable UIImage 를 actor 경계 너머로 넘기기 위한 박스 (UIImage 는 Sendable 아님).
/// `LocalThumbnail` 밖(파일 스코프)에 둬서 `Placeholder` 제네릭을 끌고 들어가지 않게 한다.
private struct LoadedThumbnail: @unchecked Sendable {
    let image: UIImage
    let bottomLuminance: CGFloat?
}

private func loadDownsampledContainerImage(
    relativePath: String?,
    maxPixel: Int,
    /// non-nil 이면 이 비율(w/h)의 프레임에 center fill 했을 때 보이는 하단 영역의 휘도를 계산.
    visibleAspectForLuminance: CGFloat? = nil
) async -> LoadedThumbnail? {
    guard let relativePath else { return nil }
    let url = AppGroup.containerURL.appendingPathComponent(relativePath)
    return await Task.detached(priority: .userInitiated) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return LoadedThumbnail(
            image: UIImage(cgImage: cgImage),
            bottomLuminance: visibleAspectForLuminance.flatMap {
                bottomRegionLuminance(of: cgImage, visibleAspect: $0)
            }
        )
    }.value
}

/// center aspect-fill 시 보이는 영역 하단 35% 의 평균 휘도(rec.709, 0~1) — 근사 휴리스틱.
/// 다운샘플된 썸네일의 해당 crop 을 8×8 컨텍스트에 그려 64 샘플을 직접 평균한다 (~ms 급).
/// 정확한 box-average 는 아니고, premultiplied alpha 라 투명 영역은 검정으로 치우치지만
/// 캡처(불투명 스크린샷) 스크림 강도 용도엔 충분하다.
/// (kCGImageSourceCreateThumbnailWithTransform 으로 orientation 이 이미 보정돼 비트맵 하단 = 시각적 하단.
///  CGImage.cropping 의 좌표 원점은 비트맵 top-left.)
private func bottomRegionLuminance(of cgImage: CGImage, visibleAspect: CGFloat) -> CGFloat? {
    let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
    guard width > 0, height > 0, visibleAspect > 0 else { return nil }
    // 세로 이미지를 visibleAspect 프레임에 fill 하면 위아래가 잘린다 — 글씨가 얹히는 곳은
    // *보이는* 하단이므로 잘려나간 부분(홈 인디케이터·하단 바 등)은 측정에서 뺀다.
    let visibleHeight = min(height, width / visibleAspect)
    let visibleTop = (height - visibleHeight) / 2
    let cropHeight = max(1, visibleHeight * 0.35)
    let cropRect = CGRect(x: 0, y: visibleTop + visibleHeight - cropHeight, width: width, height: cropHeight)
    guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
    let side = 8
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let context = CGContext(
        data: &pixels,
        width: side, height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .medium
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
    var total: CGFloat = 0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
        total += 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    return total / CGFloat(side * side)
}
