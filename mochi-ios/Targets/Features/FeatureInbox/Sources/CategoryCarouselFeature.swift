import Foundation
import ComposableArchitecture
import CoreDomain
import DesignSystem

/// 홈 "이런 걸 모아두셨어요" 한 칸이 들고 다니는 카테고리 묶음.
///
/// 호출부(`MainTabFeature`·`MonthlyDigestFeature`)에서 한 번 집계하고, 진입 시 이 값을
/// 그대로 ``CategoryCarouselFeature`` 에 넘겨 즉시 턴테이블을 띄운다(별도 재조회 없이 스냅샷 표시 —
/// 회수 목록(`RecallListFeature`)이 홈 피드를 그대로 넘겨받는 패턴과 동일).
///
/// - `count` 는 표시용 전체 기록 수, `items` 는 턴테이블에 띄울 **대표 항목(상한 적용)** 이다.
///   둘이 어긋날 수 있다(예: 120개 기록 중 대표 30개만 회전) — 시안 프로토타입도 카운트와 커버 수를
///   분리한다. 수백 개를 한 ZStack 에 그리지 않기 위한 의도된 상한이다.
public struct CategoryBucket: Equatable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let count: Int
    public let items: [MochiItem]
    /// 색 인덱스 — ``MochiCategoryPalette`` 를 순환 참조해 홈 그리드와 턴테이블이 같은 색을 쓴다.
    public let tintIndex: Int

    public init(name: String, count: Int, items: [MochiItem], tintIndex: Int) {
        self.name = name
        self.count = count
        self.items = items
        self.tintIndex = tintIndex
    }
}

/// 카테고리 턴테이블 — 한 카테고리의 기억들을 3D 누운 원판(LP 턴테이블)으로 펼쳐 돌려보는 화면.
///
/// 회전·관성·스냅 같은 인터랙션은 전부 뷰(`CategoryCarouselView`)의 로컬 상태다 — reducer 는
/// "어떤 기억을 열까"만 책임진다(초점 커버 탭 / "이 기억 열기" → 상위가 상세 present).
@Reducer
public struct CategoryCarouselFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public let bucket: CategoryBucket

        public init(bucket: CategoryBucket) {
            self.bucket = bucket
        }
    }

    public enum Action: Sendable {
        /// 초점 커버 탭 — 그 항목 상세를 연다. hero 는 초점 커버의 글로벌 frame(상세로 확대되는 시작점,
        /// 캡처 못 했으면 nil → 중앙 scale 폴백).
        case openItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Sendable {
            /// 상위(MainTab)가 그 항목 상세를 hero 확대로 present 한다(로컬 id — 홈에서 이미 들고 있던 항목).
            case openItem(itemID: UUID, hero: HeroSourceFrames?)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case let .openItemTapped(id, hero):
                return .send(.delegate(.openItem(itemID: id, hero: hero)))
            case .delegate:
                return .none
            }
        }
    }
}
