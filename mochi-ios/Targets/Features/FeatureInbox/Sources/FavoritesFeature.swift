import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import DesignSystem

/// 즐겨찾기 화면 reducer — 홈 헤더 별로 진입(MonthlyDigest 와 같은 path push 패턴).
///
/// 즐겨찾기는 "사용자가 모찌에게 준 중요 신호"고, 이 화면은 모찌가 그 신호로 다시 꺼내 보여주는
/// 회수 표면이다(PRODUCT §1.5). 항목 탭 → 공용 상세(delegate 로 상위가 present). 서버 list 라우트
/// 없이 로컬 Realm 을 `isFavorite` 로 필터한다(즐겨찾기 토글이 서버 동기화라 재설치 후에도 복원됨).
@Reducer
public struct FavoritesFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var items: [MochiItem] = []
        public var isLoading: Bool = true
        public init() {}
    }

    public enum Action: Sendable {
        case onAppear
        case loaded([MochiItem])
        case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
        case deleteTapped(MochiItem.ID)
        case delegate(Delegate)

        public enum Delegate: Sendable, Equatable {
            case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
        }
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    await send(.loaded(await favorites()))
                    // 즐겨찾기 해제·삭제·동기화 변화를 반영해 목록을 갱신한다(검색 탭과 같은 구독 패턴).
                    for await _ in repository.observeChanges() {
                        await send(.loaded(await favorites()))
                    }
                }

            case let .loaded(items):
                state.items = items
                state.isLoading = false
                return .none

            case let .mochiItemTapped(id, hero):
                return .send(.delegate(.mochiItemTapped(id, hero: hero)))

            case let .deleteTapped(id):
                state.items.removeAll { $0.id == id }
                return .run { [repository, apiClient] _ in
                    if let item = try? await repository.find(id: id),
                       case let .uploaded(serverID, _) = item.syncState {
                        try? await apiClient.deleteMochiItem(mochiServerID: serverID)
                    }
                    try? await repository.delete(id: id)
                }

            case .delegate:
                return .none
            }
        }
    }

    private func favorites() async -> [MochiItem] {
        let all = (try? await repository.listRecent(limit: 500)) ?? []
        return all.filter(\.isFavorite)
    }
}
