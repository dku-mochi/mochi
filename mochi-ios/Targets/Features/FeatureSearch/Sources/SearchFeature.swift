import Foundation
import ComposableArchitecture
import CoreDomain

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
        case recentTapped(MochiItem.ID)        // 카드 탭 → 상세 (MainTabFeature 가 path.append)
        case cardMoreTapped(MochiItem.ID)      // ⋯ → action sheet (D5.5)

        // 빈 결과 CTA
        case retryAllTapped                    // "전체에서 다시 찾기" — 필터만 reset (query 유지)
        case clearFiltersTapped                // 검색 탭 재탭 / clear 버튼 — 모두 reset

        // 내부
        case resultsLoaded([SearchResult])
        case delegate(Delegate)

        public enum Delegate: Sendable {
            case shareRequested(MochiItem.ID)
            case changeIntentRequested(MochiItem.ID)
            case deleteRequested(MochiItem.ID)
        }
    }

    @Dependency(\.searchService) var searchService

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
                if state.items.isEmpty {
                    state.items = SampleMochiItems.designDemo()
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
                // MainTabFeature 가 path.append(.detail).
                return .none

            case .cardMoreTapped:
                // D5.5 — view 측 action sheet 발사.
                return .none

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

    private enum CancelID { case search }

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
