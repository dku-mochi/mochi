import Foundation
import ComposableArchitecture
import CoreDomain
import CoreNetworking
import CorePersistence
import DesignSystem

/// 검색 탭 reducer — 3 phase 구조 (idle / results / empty).
///
/// 검색바 포커스는 별도 화면으로 전환하지 않는다 — idle 그리드 위에 키보드 +
/// 최근 검색 칩 한 줄만 얹힌다 (카드가 갑자기 사라지는 단절 제거, 2026-06-13 회의).
///
/// 검색 2단: 키 입력 중엔 로컬 token 매칭(즉답), return 제출 시 서버 의미 검색
/// (`POST /search` RAG citations)으로 보강 — literal 결과 우선 + semantic 추가.
@Reducer
public struct SearchFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var query: String = ""
        public var isFocused: Bool = false
        public var typeFilter: SearchD5.TypeFilter = .all
        /// 카테고리 필터(주간 리포트와 같은 정규화 category). nil = 전체 카테고리.
        /// idle 그리드와 검색 결과 양쪽의 단일 필터 축 — 고른 채 검색하면 그 카테고리 안에서만 찾는다.
        public var selectedCategory: String?
        public var items: [MochiItem] = []
        public var results: [SearchResult] = []
        public var isSearching: Bool = false
        /// 서버 의미 검색 in-flight — 결과 요약 줄의 "더 찾는 중" 표시 + empty phase 보류.
        public var isSemanticSearching: Bool = false
        public var recentSearches: [String] = []

        public init() {}

        public enum Phase: Equatable, Sendable {
            case idle      // 기본 그리드 — query 빈 상태 (포커스 여부 무관, 그리드 유지)
            case results   // query 있음 + 결과 ≥ 1 — 2col 그리드 + intent 필터
            case empty     // query 있음 + 결과 0 — 모찌(?) + CTA
        }

        public var phase: Phase {
            if query.isEmpty { return .idle }
            // 로컬 or 서버 검색이 도는 동안엔 빈 결과를 단정하지 않는다.
            if (isSearching || isSemanticSearching) && results.isEmpty { return .results }
            return results.isEmpty ? .empty : .results
        }

        /// 기본 화면 그리드의 표시 items — 타입(드롭다운) ∧ 카테고리(칩) 동시 적용(AND).
        public var filteredItems: [MochiItem] {
            items.filter {
                typeFilter.matches($0)
                    && (selectedCategory == nil || $0.analysis?.category == selectedCategory)
            }
        }

        /// 카테고리 칩 집합 — 전체 기록의 정규화 category 를 많은 순으로(주간 리포트 카테고리와 같은 소스).
        /// 빈 category 는 제외. 신규 유저(카테고리 없음)면 빈 배열 → 칩 행은 "전체"만 표시.
        public var availableCategories: [String] {
            var counts: [String: Int] = [:]
            var order: [String] = []
            for item in items {
                guard let c = item.analysis?.category, !c.isEmpty else { continue }
                if counts[c] == nil { order.append(c) }
                counts[c, default: 0] += 1
            }
            // count 내림차순, 동률은 첫 등장 순.
            return order.sorted { lhs, rhs in
                let cl = counts[lhs] ?? 0, cr = counts[rhs] ?? 0
                if cl != cr { return cl > cr }
                return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
            }
        }
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        case onAppear

        // return 제출 — 최근 검색어 저장 + 서버 의미 검색 보강.
        case submit

        // 검색바 / 필터
        case searchBarFocused(Bool)
        case typeFilterTapped(SearchD5.TypeFilter)
        case categoryTapped(String?)           // 카테고리 칩 (nil = 전체) — 그리드·검색 공용 단일 필터

        // 최근 검색 칩 row (포커스 + query 빈 상태에서 검색바 아래 한 줄)
        case recentSearchTapped(String)        // 최근 검색 칩
        case removeRecentSearchTapped(String)  // 칩 long-press → 개별 삭제
        case clearRecentSearchesTapped         // "모두 지우기"

        // 그리드 pull-to-refresh — 백엔드 sync 1회 트리거 (반영은 observeChanges 가)
        case refreshPulled

        // 카드
        case recentTapped(MochiItem.ID, HeroSourceFrames?)  // 카드 탭 → 상세 hero present (MainTabFeature)
        case deleteTapped(MochiItem.ID)        // contextMenu/⋯ 삭제
        case favoriteToggled(MochiItem.ID)     // contextMenu 즐겨찾기 추가/해제

        // 빈 결과 CTA
        case askMochiTapped                    // "모찌에게 물어보기" — 채팅으로 query 넘김
        case retryAllTapped                    // "전체에서 다시 찾기" — 필터만 reset (query 유지)
        case clearFiltersTapped                // 검색 탭 재탭 / clear 버튼 — 모두 reset

        // 내부
        case itemsLoaded([MochiItem])
        case resultsLoaded([SearchResult])
        case semanticResultsLoaded(SearchResponse?)
        case delegate(Delegate)

        public enum Delegate: Sendable {
            /// 빈 결과에서 "모찌에게 물어보기" — MainTab 이 채팅을 query 첫 메시지로 push.
            case askChatRequested(String)
        }
    }

    @Dependency(\.searchService) var searchService
    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.continuousClock) var clock

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
                state.recentSearches = Self.loadRecentSearches()
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
                state.items = items
                // 고른 카테고리의 마지막 항목이 삭제/재분류되면 그 칩이 칩 행에서 사라진다 —
                // selectedCategory 만 남으면 활성 칩 없이 그리드가 비는 혼란. 사라진 카테고리는 전체로 정규화.
                if let c = state.selectedCategory, !state.availableCategories.contains(c) {
                    state.selectedCategory = nil
                }
                // 검색 중이었다면 새 dataset 위에서 결과 재계산.
                if !state.query.isEmpty {
                    return self.updateSearch(&state)
                }
                return .none

            case .submit:
                state.isFocused = false
                let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return .none }
                Self.saveRecentSearch(query, into: &state)
                return self.semanticSearch(&state)

            case let .searchBarFocused(focused):
                state.isFocused = focused
                return .none

            case let .typeFilterTapped(filter):
                state.typeFilter = filter
                // 검색 중이면 새 종류 scope 안에서 즉시 결과 재계산.
                return state.query.isEmpty ? .none : self.updateSearch(&state)

            case let .categoryTapped(category):
                // 같은 칩 재탭 = 해제(전체). 타입과 독립(AND).
                state.selectedCategory = (state.selectedCategory == category) ? nil : category
                // 검색 중이면 고른 카테고리 안에서만 결과가 남도록 재계산.
                return state.query.isEmpty ? .none : self.updateSearch(&state)

            case let .recentSearchTapped(term):
                state.query = term
                state.isFocused = false
                Self.saveRecentSearch(term, into: &state)
                return .merge(self.updateSearch(&state), self.semanticSearch(&state))

            case let .removeRecentSearchTapped(term):
                state.recentSearches.removeAll { $0 == term }
                UserDefaults.standard.set(state.recentSearches, forKey: Self.recentSearchesKey)
                return .none

            case .clearRecentSearchesTapped:
                state.recentSearches = []
                UserDefaults.standard.removeObject(forKey: Self.recentSearchesKey)
                return .none

            case .refreshPulled:
                // 업로드 대기분 push + 분석 폴링 1회 — 변경 반영은 observeChanges 루프가 한다.
                return .run { [syncTrigger] _ in
                    await syncTrigger.runOnce()
                }

            case .recentTapped:
                // MainTabFeature 가 hero present (state.detail).
                return .none

            case let .deleteTapped(id):
                // 낙관 제거(즉시 UI 반영) + 홈과 동일한 삭제 규약 — 업로드된 항목만 서버 soft delete,
                // 로컬 Realm 은 hard delete(서버 캐시).
                state.items.removeAll { $0.id == id }
                state.results.removeAll { $0.item.id == id }
                return .run { [repository, apiClient] _ in
                    if let item = try? await repository.find(id: id),
                       case let .uploaded(serverID, _) = item.syncState {
                        try? await apiClient.deleteMochiItem(mochiServerID: serverID)
                    }
                    try? await repository.delete(id: id)
                }

            case let .favoriteToggled(id):
                // 즐겨찾기 토글 — 카드엔 시각 표시가 없어(요구사항 밖) 낙관적 state 변경 불필요.
                // 로컬 write → observeChanges 가 items 재로드, 서버 push(실패 시 FavoriteSync 가 롤백).
                // 실패 메시지는 surface 하지 않는다 — 카드엔 표시가 없고 롤백 후 observe 가 재로드하므로
                // 무음 처리. 연타는 cancelInFlight 로 최신 토글만 살려 server↔local 불일치를 막는다.
                return .run { [repository, apiClient] _ in
                    guard let item = try? await repository.find(id: id) else { return }
                    let target = !item.isFavorite
                    try? await repository.setFavorite(mochiItemID: id, isFavorite: target)
                    _ = await FavoriteSync.pushToggle(
                        item: item, isFavorite: target, repository: repository, apiClient: apiClient
                    )
                }
                .cancellable(id: CancelID.favorite(id), cancelInFlight: true)

            case .askMochiTapped:
                return .send(.delegate(.askChatRequested(state.query)))

            case .retryAllTapped:
                state.typeFilter = .all
                state.selectedCategory = nil
                return .merge(self.updateSearch(&state), self.semanticSearch(&state))

            case .clearFiltersTapped:
                state.query = ""
                state.typeFilter = .all
                state.selectedCategory = nil
                state.results = []
                state.isSearching = false
                state.isSemanticSearching = false
                state.isFocused = false
                // in-flight 결과가 빈 query 상태에 잔류하는 것 방지.
                return .merge(.cancel(id: CancelID.search), .cancel(id: CancelID.semantic))

            case let .resultsLoaded(results):
                state.results = results
                state.isSearching = false
                return .none

            case let .semanticResultsLoaded(response):
                state.isSemanticSearching = false
                guard let response else { return .none }
                // citations 의 서버 id 를 로컬 항목으로 역매핑(syncState.uploaded) —
                // literal 결과에 없는 항목만 score 순으로 뒤에 추가.
                var byServerID: [UUID: MochiItem] = [:]
                for item in state.items {
                    if case let .uploaded(serverID, _) = item.syncState {
                        byServerID[serverID] = item
                    }
                }
                let existing = Set(state.results.map(\.item.id))
                let typeFilter = state.typeFilter
                let category = state.selectedCategory
                let additions = response.citations
                    .sorted { $0.score > $1.score }
                    .compactMap { byServerID[$0.mochiItemID] }
                    .filter { !existing.contains($0.id) }
                    // 의미 검색 보강분도 현재 종류 ∧ 카테고리 scope 를 지킨다 — 칩 밖 항목이 섞이지 않게.
                    .filter { typeFilter.matches($0) && (category == nil || $0.analysis?.category == category) }
                state.results.append(contentsOf: additions.map { SearchResult(item: $0, isSemantic: true) })
                return .none

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - Helpers

    private enum CancelID: Hashable { case search, observe, semantic, favorite(MochiItem.ID) }

    private func updateSearch(_ state: inout State) -> Effect<Action> {
        if state.query.isEmpty {
            state.results = []
            state.isSearching = false
            state.isSemanticSearching = false
            // 새 키스트로크는 이전 제출의 semantic 결과도 무효화한다.
            return .merge(.cancel(id: CancelID.search), .cancel(id: CancelID.semantic))
        }
        state.isSearching = true
        let query = state.query
        // 검색 대상은 종류 ∧ 카테고리로 이미 좁힌 집합 — 고른 칩 안에서만 토큰 매칭한다.
        let dataset = state.filteredItems
        // 디바운스 200ms — 빠른 타이핑 중 글자마다 dataset 캡처 + 검색 + results 통째 교체
        // (보이는 카드 전부 diff)가 돌면 키 입력이 버벅인다. 멈췄을 때 1회만.
        // cancelInFlight: 늦게 도착한 stale 결과가 최신을 덮지 않게.
        return .merge(
            .cancel(id: CancelID.semantic),
            .run { [searchService, clock] send in
                try? await clock.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let results = await searchService.search(query: query, in: dataset)
                await send(.resultsLoaded(results))
            }
            .cancellable(id: CancelID.search, cancelInFlight: true)
        )
    }

    /// 서버 의미 검색(RAG citations) — return 제출·최근 검색 탭에서만. 실패/오프라인은 조용히 무시
    /// (로컬 literal 결과가 이미 떠 있다).
    ///
    /// scope 는 항상 `.all` — 카테고리는 서버 검색 파라미터가 아니라 정규화 라벨이므로,
    /// 보강분의 카테고리 필터는 `semanticResultsLoaded` 에서 클라이언트가 적용한다.
    private func semanticSearch(_ state: inout State) -> Effect<Action> {
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .none }
        state.isSemanticSearching = true
        return .run { [apiClient] send in
            let response = try? await apiClient.search(query: query, scope: .all)
            await send(.semanticResultsLoaded(response))
        }
        .cancellable(id: CancelID.semantic, cancelInFlight: true)
    }

    // MARK: - 최근 검색어 (UserDefaults)

    private static let recentSearchesKey = "app.mochi.search.recentSearches"
    private static let recentSearchesCap = 10

    private static func loadRecentSearches() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
    }

    private static func saveRecentSearch(_ term: String, into state: inout State) {
        var list = state.recentSearches
        list.removeAll { $0 == term }
        list.insert(term, at: 0)
        if list.count > recentSearchesCap { list = Array(list.prefix(recentSearchesCap)) }
        state.recentSearches = list
        UserDefaults.standard.set(list, forKey: recentSearchesKey)
    }
}
