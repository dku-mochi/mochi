import Kingfisher
import SwiftUI

/// 원격 사진 미니 타일 — 장소 카드의 매장 사진처럼 "실물 단서"를 작은 타일로 되살린다.
///
/// LocalThumbnail(로컬 캡처)·FaviconTile(파비콘)과 같은 계열의 원격 이미지판. Kingfisher
/// 디스크 캐시로 재방문 즉시 뜨고, 타일 크기로 다운샘플링해 원본(수백 KB)을 메모리에
/// 올리지 않는다. 로딩·실패 시엔 은은한 플레이스홀더 — URL 부재 시 아예 안 그리는 것은
/// 호출부 책임(빈 회색 타일을 상시 노출하지 않는다).
public struct RemotePhotoTile: View {
    private let url: URL?
    private let size: CGFloat
    private let cornerRadius: CGFloat

    public init(url: URL?, size: CGFloat, cornerRadius: CGFloat) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        KFImage(url)
            .setProcessor(DownsamplingImageProcessor(size: CGSize(width: size, height: size)))
            .scaleFactor(UIScreen.main.scale)
            .placeholder { placeholder }
            .fade(duration: 0.2)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            HomeDesign.Color.ink100
            Image(systemName: "photo")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textFaint)
        }
    }
}
