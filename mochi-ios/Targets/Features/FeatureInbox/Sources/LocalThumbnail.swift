import SwiftUI
import ImageIO
import CorePersistence

/// App Group 컨테이너에 저장된 캡처(스크린샷) 이미지를 비동기로 로드·다운샘플해 표시한다.
///
/// 홈의 가로 스크롤 카드는 여러 셀이 동시에 보이므로, full-res 스크린샷을 메인 스레드에서
/// 동기 디코드하면 스크롤이 끊긴다. ImageIO 썸네일 API 로 셀 크기에 맞춰 다운샘플하고
/// `Task.detached` 로 디코드를 메인 밖으로 뺀다. 경로가 nil 이거나 로드 실패 시 `placeholder` 폴백.
///
/// 같은 디스크 read 패턴은 Live Activity 의 `ThumbnailColumn` / ShareExtension 의
/// `SharePreviewImage` 에도 있다 (App Group container + `ImageRef.relativePath`).
struct LocalThumbnail<Placeholder: View>: View {
    let relativePath: String?
    let targetSize: CGSize
    /// `.fill` 로 채운 이미지가 프레임을 넘칠 때 어느 쪽을 보여줄지. 스크린샷(세로 비율)은
    /// `.top` 으로 상단(상태바·제목)을 보여주는 게 알아보기 쉽다. 기본 `.center`.
    var alignment: Alignment = .center
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            } else {
                placeholder()
            }
        }
        // `.fill` 오버플로를 프레임 경계에서 잘라 호출부 레이아웃(예: 헤드라인)을 침범하지 않게 한다.
        .clipped()
        .task(id: relativePath) {
            // @3x 까지 커버하도록 셀 변 길이의 3배를 상한 픽셀로 둔다.
            let maxPixel = Int(max(targetSize.width, targetSize.height) * 3)
            image = await loadDownsampledContainerImage(relativePath: relativePath, maxPixel: maxPixel)?.image
        }
    }
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
