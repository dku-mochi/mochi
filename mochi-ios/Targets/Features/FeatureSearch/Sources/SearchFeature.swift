import Foundation
import ComposableArchitecture
import CoreDomain
import CoreNetworking
import CorePersistence
import DesignSystem

/// 검색 탭 reducer — 4 phase 구조 (idle / focused / results / empty).
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
        public var selectedIntent: Intent?
        public var items: [MochiItem] = []
        public var results: [SearchResult] = []
        public var isSearching: Bool = false
        /// 서버 의미 검색 in-flight — 결과 요약 줄의 "더 찾는 중" 표시 + empty phase 보류.
        public var isSemanticSearching: Bool = false
        public var recentSearches: [String] = []

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
            // 로컬 or 서버 검색이 도는 동안엔 빈 결과를 단정하지 않는다.
            if (isSearching || isSemanticSearching) && results.isEmpty { return .results }
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

        // return 제출 — 최근 검색어 저장 + 서버 의미 검색 보강.
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
        case deleteTapped(MochiItem.ID)        // contextMenu/⋯ 삭제

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
                return .none

            case let .intentChipTapped(intent):
                state.selectedIntent = (state.selectedIntent == intent) ? nil : intent
                return self.updateSearch(&state)

            case let .recentSearchTapped(term):
                state.query = term
                state.isFocused = false
                state.selectedIntent = nil
                Self.saveRecentSearch(term, into: &state)
                return .merge(self.updateSearch(&state), self.semanticSearch(&state))

            case .clearRecentSearchesTapped:
                state.recentSearches = []
                UserDefaults.standard.removeObject(forKey: Self.recentSearchesKey)
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

            case .askMochiTapped:
                return .send(.delegate(.askChatRequested(state.query)))

            case .retryAllTapped:
                state.typeFilter = .all
                state.selectedIntent = nil
                return .merge(self.updateSearch(&state), self.semanticSearch(&state))

            case .clearFiltersTapped:
                state.query = ""
                state.typeFilter = .all
                state.selectedIntent = nil
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
                let additions = response.citations
                    .sorted { $0.score > $1.score }
                    .compactMap { byServerID[$0.mochiItemID] }
                    .filter { !existing.contains($0.id) }
                state.results.append(contentsOf: additions.map { SearchResult(item: $0) })
                return .none

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - Helpers

    private enum CancelID { case search, observe, semantic }

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
        let intent = state.selectedIntent
        let dataset = state.items
        // cancelInFlight: 키스트로크마다 발사되므로 늦게 도착한 stale 결과가 최신을 덮지 않게.
        return .merge(
            .cancel(id: CancelID.semantic),
            .run { [searchService] send in
                let results = await searchService.search(
                    query: query,
                    intent: intent,
                    in: dataset
                )
                await send(.resultsLoaded(results))
            }
            .cancellable(id: CancelID.search, cancelInFlight: true)
        )
    }

    /// 서버 의미 검색(RAG citations) — return 제출·최근 검색 탭에서만. 실패/오프라인은 조용히 무시
    /// (로컬 literal 결과가 이미 떠 있다).
    private func semanticSearch(_ state: inout State) -> Effect<Action> {
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .none }
        state.isSemanticSearching = true
        let scope = Self.scope(for: state.selectedIntent)
        return .run { [apiClient] send in
            let response = try? await apiClient.search(query: query, scope: scope)
            await send(.semanticResultsLoaded(response))
        }
        .cancellable(id: CancelID.semantic, cancelInFlight: true)
    }

    private static func scope(for intent: Intent?) -> SearchScope {
        switch intent {
        case .schedule:  return .schedule
        case .todo:      return .todo
        case .knowledge: return .knowledge
        case .memo:      return .memo
        case nil:        return .all
        }
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
