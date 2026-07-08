import Foundation

/// Agent 가 `entities(kind=place)` 로 남긴 장소 정보 — 기록 상세의 지도 섹션이 그린다.
///
/// 서버 `searchPlaceGeo` tool 이 네이버 지역검색 실매칭으로 완성한 값이라 좌표가 발명되지 않는다
/// (일치 후보가 없으면 서버가 place 자체를 내려주지 않는다). 좌표는 WGS84, 아이템당 최대 1개.
public struct Place: Equatable, Sendable, Hashable, Codable {
    /// 장소 이름 (상호). 지도 annotation·카드 제목.
    public let name: String
    /// WGS84 위도.
    public let lat: Double
    /// WGS84 경도.
    public let lng: Double
    /// 네이버 업종 경로 ("카페,디저트>카페"). 표시할 땐 `categoryLeaf` 를 쓴다. 없을 수 있다.
    public let category: String?
    /// 지번 주소. 없을 수 있다.
    public let address: String?
    /// 도로명 주소. 카드 부제는 이걸 우선한다. 없을 수 있다.
    public let roadAddress: String?
    /// 네이버 지도 검색 URL (지역검색이 place id 를 안 줘 직링크 대신 검색 URL). 없을 수 있다.
    public let mapURL: URL?
    /// 별점 0~5 — Google Places 보강 값(서버가 네이버 후보와 좌표 매칭됐을 때만 내려준다). 없을 수 있다.
    public let rating: Double?
    /// 리뷰 수. `rating` 있을 때만 의미. 없을 수 있다.
    public let ratingCount: Int?
    /// 매장 사진 URL (googleusercontent — 서버 projection 에서 host 검증 완료). 없을 수 있다.
    public let imageURL: URL?

    /// 업종 경로의 마지막 마디 — 카드에 보여줄 짧은 업종명 ("카페,디저트>카페" → "카페").
    public var categoryLeaf: String? {
        guard let category, !category.isEmpty else { return nil }
        return category.split(separator: ">").last.map(String.init)
    }

    /// 카드 부제로 쓸 주소 — 도로명 우선, 없으면 지번.
    public var displayAddress: String? {
        if let roadAddress, !roadAddress.isEmpty { return roadAddress }
        if let address, !address.isEmpty { return address }
        return nil
    }

    /// 카드에 보여줄 별점 문자열 ("4.6") — 소수 1자리 고정. rating 없으면 nil.
    public var ratingText: String? {
        rating.map { String(format: "%.1f", $0) }
    }

    /// 리뷰 수 표기 ("1,234") — 천 단위 구분. ratingCount 없으면 nil.
    public var ratingCountText: String? {
        guard let ratingCount else { return nil }
        return ratingCount.formatted(.number.grouping(.automatic))
    }

    public init(
        name: String,
        lat: Double,
        lng: Double,
        category: String? = nil,
        address: String? = nil,
        roadAddress: String? = nil,
        mapURL: URL? = nil,
        rating: Double? = nil,
        ratingCount: Int? = nil,
        imageURL: URL? = nil
    ) {
        self.name = name
        self.lat = lat
        self.lng = lng
        self.category = category
        self.address = address
        self.roadAddress = roadAddress
        self.mapURL = mapURL
        self.rating = rating
        self.ratingCount = ratingCount
        self.imageURL = imageURL
    }
}
