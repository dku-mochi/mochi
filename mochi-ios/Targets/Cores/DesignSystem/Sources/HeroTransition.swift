import SwiftUI

/// 기록 카드 탭 시 App 레이어로 전달되는 카드의 글로벌 frame 묶음.
/// `cardImage`(스크린샷 썸네일 영역)가 있으면 그 이미지만 상세 hero 이미지로 비행하고,
/// 없으면(memo/url) `card`(카드 통째)는 폴백 정보로만 쓰인다.
/// `imageRelativePath` 는 비행에 쓸 **원본 캡처**의 경로 — App 레이어가 직접 로드해 배지·테두리
/// 없는 순수 이미지를 비행시킨다(화면 비트맵을 뜨면 카드 배지가 같이 확대돼 어색하므로).
public struct HeroSourceFrames: Equatable, Sendable {
    public var card: CGRect
    public var cardImage: CGRect?
    public var imageRelativePath: String?

    public init(card: CGRect, cardImage: CGRect? = nil, imageRelativePath: String? = nil) {
        self.card = card
        self.cardImage = cardImage
        self.imageRelativePath = imageRelativePath
    }
}
