import Foundation
import ComposableArchitecture
import CoreDomain
import CoreNetworking
import CorePersistence
import DesignSystem

/// 검색 탭 reducer — 새 시안(D5+) 4 phase 구조.
///
/// Phase 자동 계산: query + isFocused + results 의 조합으로 결정.
@Reducer
public struct SearchFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var query: String = ""
        public var isFocused: Bool = false
        public var typeFilter: SearchD5.TypeFilter = .all
        public var selectedIntent: Intent?
        public var items: [MochiItem] = []
        public var results: [SearchResult] = []
        public var isSearching: Bool = false

        public init() {}

        public enum Phase: Equatable, Sendable {
            case idle      // 기본 그리드 — 검색바 빈 상태 + 포커스 X
            case focused   // 검색바 포커스 + query 빈 상태 — 모찌(♥) + 최근/빠른 검색
            case results   // query 있음 + 결과 ≥ 1 — 2col 그리드 + intent 필터
            case empty     // query 있음 + 결과 0 — 모찌(?) + CTA
        }

        public var phase: Phase {
            if query.isEmpty {
                return isFocused ? .focused : .idle
            }
            if isSearching && results.isEmpty { return .results }   // 검색 중
            return results.isEmpty ? .empty : .results
        }

        /// 기본 화면 그리드의 표시 items — typeFilter 적용.
        public var filteredItems: [MochiItem] {
            items.filter { typeFilter.matches($0) }
        }
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        case onAppear

        // 외부 직접 트리거 — binding 을 거치지 않고 query 를 set 한 직후 호출하는 진입점.
        case submit

        // 검색바 / 필터
        case searchBarFocused(Bool)
        case typeFilterTapped(SearchD5.TypeFilter)
        case intentChipTapped(Intent?)

        // 시작 / 포커스 화면
        case recentSearchTapped(String)        // 최근 검색 칩
        case clearRecentSearchesTapped         // "모두 지우기"
        case quickFilterTapped(SearchD5.TypeFilter)  // 빠른 검색 칩 → typeFilter 적용 + 포커스 해제

        // 카드
        case recentTapped(MochiItem.ID, HeroSourceFrames?)  // 카드 탭 → 상세 hero present (MainTabFeature)
        case deleteTapped(MochiItem.ID)        // contextMenu/⋯ 삭제 — mock 단계: 로컬 dataset 에서만 제거

        // 빈 결과 CTA
        case retryAllTapped                    // "전체에서 다시 찾기" — 필터만 reset (query 유지)
        case clearFiltersTapped                // 검색 탭 재탭 / clear 버튼 — 모두 reset

        // 내부
        case itemsLoaded([MochiItem])
        case resultsLoaded([SearchResult])
        case delegate(Delegate)

        public enum Delegate: Sendable {
            case shareRequested(MochiItem.ID)
            case changeIntentRequested(MochiItem.ID)
            case deleteRequested(MochiItem.ID)
        }
    }

    @Dependency(\.searchService) var searchService
    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.query):
                return self.updateSearch(&state)
            case .binding:
                return .none

            case .onAppear:
                // 실제 데이터(로컬 Realm = 서버 캐시) 로드 + 쓰기 발생 시 자동 재로드(홈과 동일 패턴).
                // 탭 재진입마다 호출되므로 cancelInFlight 로 observe 루프를 1개로 유지.
                return .run { [repository] send in
                    if let items = try? await repository.listRecent(limit: 200) {
                        await send(.itemsLoaded(items))
                    }
                    for await _ in repository.observeChanges() {
                        if let items = try? await repository.listRecent(limit: 200) {
                            await send(.itemsLoaded(items))
                        }
                    }
                }
                .cancellable(id: CancelID.observe, cancelInFlight: true)

            case let .itemsLoaded(items):
                // 저장소가 완전히 비어있으면(첫 로그인 직후 등) 디자인 시연용 mock 시드 폴백.
                state.items = items.isEmpty ? SampleMochiItems.designDemo() : items
                // 검색 중이었다면 새 dataset 위에서 결과 재계산.
                if !state.query.isEmpty {
                    return self.updateSearch(&state)
                }
                return .none

            case .submit:
                // 외부에서 query 를 직접 set 한 뒤 호출 (홈 라우팅은 2026-06-10 채팅 탭으로 전환됨).
                state.isFocused = false
                return self.updateSearch(&state)

            case let .searchBarFocused(focused):
                state.isFocused = focused
                return .none

            case let .typeFilterTapped(filter):
                state.typeFilter = filter
                return .none

            case let .intentChipTapped(intent):
                state.selectedIntent = (state.selectedIntent == intent) ? nil : intent
                return self.updateSearch(&state)

            case let .recentSearchTapped(term):
                state.query = term
                state.isFocused = false
                state.selectedIntent = nil
                return self.updateSearch(&state)

            case .clearRecentSearchesTapped:
                // mock 단계 — 정적 리스트라 동작 placeholder.
                return .none

            case let .quickFilterTapped(filter):
                state.typeFilter = filter
                state.isFocused = false
                return .none

            case .recentTapped:
                // MainTabFeature 가 hero present (state.detail).
                return .none

            case let .deleteTapped(id):
                // 낙관 제거(즉시 UI 반영) + 홈과 동일한 삭제 규약 — 업로드된 항목만 서버 soft delete,
                // 로컬 Realm 은 hard delete(서버 캐시). mock 폴백 항목은 repository 에 없어 no-op.
                state.items.removeAll { $0.id == id }
                state.results.removeAll { $0.item.id == id }
                return .run { [repository, apiClient] _ in
                    if let item = try? await repository.find(id: id),
                       case let .uploaded(serverID, _) = item.syncState {
                        try? await apiClient.deleteMochiItem(mochiServerID: serverID)
                    }
                    try? await repository.delete(id: id)
                }

            case .retryAllTapped:
                state.typeFilter = .all
                state.selectedIntent = nil
                return self.updateSearch(&state)

            case .clearFiltersTapped:
                state.query = ""
                state.typeFilter = .all
                state.selectedIntent = nil
                state.results = []
                state.isSearching = false
                state.isFocused = false
                return .cancel(id: CancelID.search)   // in-flight 결과가 빈 query 상태에 잔류하는 것 방지

            case let .resultsLoaded(results):
                state.results = results
                state.isSearching = false
                return .none

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - Helpers

    private enum CancelID { case search, observe }

    private func updateSearch(_ state: inout State) -> Effect<Action> {
        if state.query.isEmpty {
            state.results = []
            state.isSearching = false
            return .cancel(id: CancelID.search)
        }
        state.isSearching = true
        let query = state.query
        let intent = state.selectedIntent
        let dataset = state.items
        // cancelInFlight: 키스트로크마다 발사되므로 늦게 도착한 stale 결과가 최신을 덮지 않게.
        // mock 은 즉답이라 잠복하지만 서버 어댑터 교체(동일 시그니처) 시 그대로 race 가 된다.
        return .run { [searchService] send in
            let results = await searchService.search(
                query: query,
                intent: intent,
                in: dataset
            )
            await send(.resultsLoaded(results))
        }
        .cancellable(id: CancelID.search, cancelInFlight: true)
    }
}
