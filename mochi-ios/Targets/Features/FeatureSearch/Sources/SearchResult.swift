import Foundation
import CoreDomain

/// 검색 결과 1건 — `MochiItem` + 매칭 하이라이트 range.
///
/// 결과 카드 표현 (검색 전용 presentation) — 도메인 `MochiItem` 자체와 분리해 둠.
/// 백엔드 연결 후에는 서버 응답을 동일 형태로 매핑해 같은 UI 재사용.
public struct SearchResult: Equatable, Sendable, Hashable, Identifiable {
    public let item: MochiItem
    public let titleHighlights: [HighlightRange]
    public let summaryHighlights: [HighlightRange]
    /// 서버 의미 검색(citations)으로 보강된 항목 — literal 매칭과 구분 표시("비슷한 기억").
    public let isSemantic: Bool

    public var id: UUID { item.id }

    public init(
        item: MochiItem,
        titleHighlights: [HighlightRange] = [],
        summaryHighlights: [HighlightRange] = [],
        isSemantic: Bool = false
    ) {
        self.item = item
        self.titleHighlights = titleHighlights
        self.summaryHighlights = summaryHighlights
        self.isSemantic = isSemantic
    }
}

/// 검색어 매칭 위치 (UTF-16 offset 기반 — `NSString.range(of:)` 호환).
public struct HighlightRange: Equatable, Sendable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}
