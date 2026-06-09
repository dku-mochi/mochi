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
    /// true 면 부모 프레임을 채우는 대신 **이미지 원본 종횡비**로 표시한다(잘림·블러 레터박스 없음).
    /// 너비는 컨테이너, 높이는 비율로 자동 — 상세 화면처럼 캡처 전체를 보여줘야 할 때. 기본 false.
    var preservesAspectRatio: Bool = false
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    public init(
        relativePath: String?,
        targetSize: CGSize,
        alignment: Alignment = .center,
        preservesAspectRatio: Bool = false,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.relativePath = relativePath
        self.targetSize = targetSize
        self.alignment = alignment
        self.preservesAspectRatio = preservesAspectRatio
        self.placeholder = placeholder
    }

    public var body: some View {
        Group {
            if preservesAspectRatio {
                aspectFitBody
            } else {
                GeometryReader { geo in
                    content(geo.size)
                }
            }
        }
        .task(id: relativePath) {
            // @3x 까지 커버하도록 셀 변 길이의 3배를 상한 픽셀로 둔다.
            let maxPixel = Int(max(targetSize.width, targetSize.height) * 3)
            image = await loadDownsampledContainerImage(relativePath: relativePath, maxPixel: maxPixel)?.image
        }
    }

    /// 원본 종횡비 유지 — 부모 너비에 맞추고 높이는 이미지 비율로 자동. 잘림·레터박스 없음.
    /// 로드 전 placeholder 는 `targetSize` 비율로 임시 표시한다(로드 후 실제 비율로 확정).
    @ViewBuilder
    private var aspectFitBody: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            placeholder()
                .aspectRatio(targetSize.width / max(targetSize.height, 1), contentMode: .fit)
                .frame(maxWidth: .infinity)
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
private struct LoadedThumbnail: @unchecked Sendable { let image: UIImage }

private func loadDownsampledContainerImage(relativePath: String?, maxPixel: Int) async -> LoadedThumbnail? {
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
        return LoadedThumbnail(image: UIImage(cgImage: cgImage))
    }.value
}
