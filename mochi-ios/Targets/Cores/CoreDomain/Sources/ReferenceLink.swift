import Foundation

/// Agent 가 `entities(kind=reference_url)` 로 남긴 사용자-facing 참고 링크.
///
/// 서버 ResourceFinder 가 relevance judge 를 통과한 URL 만 골라(아이템당 최대 3개) 내려준다.
/// 상세 화면 "지금 할 수 있어요" 의 URL 카드가 이걸 그대로 그린다. `provider`·`role` 은 서버가
/// host/profile 로 결정한 분류값 문자열 — 화면은 이 두 값으로 브랜드 색·아이콘·CTA 동사를 고른다.
public struct ReferenceLink: Equatable, Sendable, Hashable, Codable, Identifiable {
    /// 실제 열 주소. 파싱 불가 URL 은 매핑 단계에서 버려진다(여기 도달하면 항상 유효).
    public let url: URL
    /// 페이지/상품 제목 — 카드 제목.
    public let title: String
    /// provider 별 CTA 문구 ("올리브영에서 보기", "캐치테이블에서 예약" 등). 서버가 완성해 보낸다.
    public let label: String
    /// 행동 종류 (`reserve`/`book`/`buy`/`read`/`reference`). 알 수 없으면 서버가 `reference`.
    public let role: String
    /// 출처 분류 (`oliveyoung`/`coupang`/`naver_map`/`info`/`visible_url`/`unknown` …). 브랜드 매핑 키.
    public let provider: String
    /// 랭킹 프로파일 (`cosmetics`/`fashion`/`local`/`electronics`/`general` …). 그룹핑 힌트.
    public let rankProfile: String
    /// 검색 소스 마커 (`visible_url`/`synthetic:coupang_search` 등). 디버깅용, 없을 수 있다.
    public let source: String?
    /// 유용도 1–5 (5 = 기록이 가리킨 바로 그 자료가 상위). 대표 링크 강조에 쓴다. 없을 수 있다.
    public let usefulness: Int?

    public var id: String { url.absoluteString }

    public init(
        url: URL,
        title: String,
        label: String,
        role: String,
        provider: String,
        rankProfile: String,
        source: String? = nil,
        usefulness: Int? = nil
    ) {
        self.url = url
        self.title = title
        self.label = label
        self.role = role
        self.provider = provider
        self.rankProfile = rankProfile
        self.source = source
        self.usefulness = usefulness
    }
}
