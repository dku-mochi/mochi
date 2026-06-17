import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

public struct SearchView: View {
    @Bindable public var store: StoreOf<SearchFeature>
    @FocusState private var isSearchFocused: Bool
    /// TextField 의 로컬 미러 — store 직접 binding 은 글자마다 reducer 동기 왕복 + body 전체
    /// 재평가가 끝나야 글자가 그려져 타이핑이 버벅인다. 입력은 로컬에 즉시 렌더하고 store 는 따라온다.
    @State private var queryText: String = ""
    /// 첫 진입 시 phaseBody 가 시차 두고 떠오르는 entrance — 홈·캘린더 `riseIn` 패턴.
    @State private var hasEntered: Bool = false

    public init(store: StoreOf<SearchFeature>) { self.store = store }

    /// 최근 검색 칩 row 표시 조건 — 포커스 + query 빈 상태 + 검색어 있음.
    /// 포커스가 별도 화면으로 전환하지 않으므로(그리드 유지) 이 한 줄이 포커스 UI 의 전부다.
    private var showsRecentChips: Bool {
        isSearchFocused && queryText.isEmpty && !store.recentSearches.isEmpty
    }

    public var body: some View {
        ZStack(alignment: .top) {
            SearchD5.Palette.bgCream.ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, SearchD5.Sizes.pageH)
                    .padding(.top, 16)
                    .padding(.bottom, 14)

                if showsRecentChips {
                    recentChipsRow
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                phaseBody
            }
            .animation(.easeInOut(duration: 0.18), value: showsRecentChips)
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.light)
        .onAppear {
            store.send(.onAppear)
            queryText = store.query
            hasEntered = true
        }
        .onChange(of: queryText) { _, newValue in
            // 로컬 입력 → store 전달 (검색 effect 는 reducer 의 200ms 디바운스가 흡수).
            if store.query != newValue {
                store.query = newValue
            }
        }
        .onChange(of: store.query) { _, newValue in
            // 외부발 변경(최근 검색 탭·X clear·탭 reselect) → 로컬 미러 sync.
            if queryText != newValue {
                queryText = newValue
            }
        }
        .onChange(of: isSearchFocused) { _, newValue in
            // 포커스가 별도 화면이 아니므로 키보드 dismiss = 포커스 해제로 단순 동기화.
            if store.isFocused != newValue {
                store.send(.searchBarFocused(newValue))
            }
        }
        .onChange(of: store.isFocused) { _, newValue in
            // reducer 가 isFocused 를 false 로 바꿀 때(최근 검색 탭·submit 등) FocusState 도 sync.
            if newValue != isSearchFocused {
                isSearchFocused = newValue
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            keyboardDismissBar
        }
        // 카드 height 고정(182/138) 레이아웃이라 무제한 확대는 잘림 — large 까지는 lineLimit 으로 안전.
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    // MARK: - Keyboard dismiss bar (검색바 포커스 시 키보드 위)

    /// 키보드가 올라오면 시스템이 bottom safe area 를 키보드 위까지 올려주므로,
    /// `.safeAreaInset(edge: .bottom)` 에 둔 view 가 자동으로 키보드 위에 stick 된다.
    ///
    /// 빈 결과(.empty)일 땐 좌측에 "모찌에게 물어보기" 제안을 함께 띄운다 —
    /// 키보드가 빈 결과 화면의 CTA 를 가려서 사용자가 기능 존재를 모른 채
    /// 지나치는 것을 막는다 (키보드 dismiss 를 요구하지 않는 발견 경로).
    @ViewBuilder
    private var keyboardDismissBar: some View {
        if isSearchFocused {
            HStack(spacing: 8) {
                if store.phase == .empty {
                    Button {
                        isSearchFocused = false
                        store.send(.askMochiTapped)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("못 찾았어요 — 모찌에게 물어보기")
                                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                .tracking(-0.2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(SearchD5.Palette.ctaGradient))
                    }
                    .buttonStyle(PressableStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                Spacer(minLength: 0)
                Button {
                    isSearchFocused = false
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(SearchD5.Palette.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(SearchD5.Palette.card)
            .overlay(
                Rectangle()
                    .fill(SearchD5.Palette.cardBorder)
                    .frame(height: 0.5),
                alignment: .top
            )
            .animation(.easeInOut(duration: 0.18), value: store.phase)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 검색바

    private var searchBar: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(SearchD5.Palette.primary)

            ZStack(alignment: .leading) {
                if queryText.isEmpty {
                    Text("기억나는 말로 찾아보세요")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(SearchD5.Palette.placeholder)
                        .allowsHitTesting(false)
                }
                TextField("", text: $queryText)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isSearchFocused)
                    .onSubmit {
                        isSearchFocused = false
                        // return 제출 — 최근 검색어 저장 + 서버 의미 검색 보강.
                        store.send(.submit)
                    }
            }

            // query 가 있을 때만 X — 빈 상태의 키보드 dismiss 는 ✓ 바가 담당.
            if !queryText.isEmpty {
                Button {
                    queryText = ""
                    store.send(.clearFiltersTapped)
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(SearchD5.Palette.textTertiary)
                        // 아이콘(18)은 그대로, 터치 영역만 44 — 바 높이(48 고정)라 바는 안 커지고,
                        // 인접 TextField 는 flexible 이라 겹침 없음.
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: SearchD5.Sizes.searchBarHeight)
        .background(
            RoundedRectangle(cornerRadius: SearchD5.Sizes.searchBarRadius, style: .continuous)
                .fill(SearchD5.Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SearchD5.Sizes.searchBarRadius, style: .continuous)
                .stroke(
                    isSearchFocused ? SearchD5.Palette.primary : SearchD5.Palette.cardBorder,
                    lineWidth: isSearchFocused ? 1.5 : 1
                )
        )
        .shadow(color: SearchD5.Palette.cardShadow.opacity(isSearchFocused ? 0.8 : 0.5),
                radius: isSearchFocused ? 14 : 10, x: 0, y: 6)
        .animation(.easeInOut(duration: 0.18), value: isSearchFocused)
    }

    // MARK: - 최근 검색 칩 row (포커스 + query 빈 상태 — 그리드 위에 한 줄만)

    private var recentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.recentSearches, id: \.self) { term in
                    RecentChip(term: term) { store.send(.recentSearchTapped(term)) }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.send(.removeRecentSearchTapped(term))
                            } label: {
                                Label("이 검색어 지우기", systemImage: "trash")
                            }
                        }
                }
                Button {
                    store.send(.clearRecentSearchesTapped)
                } label: {
                    Text("모두 지우기")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tracking(-0.2)
                        .foregroundStyle(SearchD5.Palette.primary)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, SearchD5.Sizes.pageH)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Body (phase 3 분기)

    @ViewBuilder
    private var phaseBody: some View {
        Group {
            switch store.phase {
            case .idle:
                SearchDefaultView(
                    items: store.filteredItems,
                    typeFilter: store.typeFilter,
                    onTypeFilter: { store.send(.typeFilterTapped($0)) },
                    categories: store.availableCategories,
                    selectedCategory: store.selectedCategory,
                    onCategory: { store.send(.categoryTapped($0)) },
                    onCardTap:    { id, hero in store.send(.recentTapped(id, hero)) },
                    onCardDelete: { store.send(.deleteTapped($0)) },
                    onCardToggleFavorite: { store.send(.favoriteToggled($0)) },
                    onRefresh:    { await store.send(.refreshPulled).finish() }
                )

            case .results:
                SearchResultsView(
                    query: store.query,
                    results: store.results,
                    selectedIntent: store.selectedIntent,
                    isSemanticSearching: store.isSemanticSearching,
                    onIntent:     { store.send(.intentChipTapped($0)) },
                    onCardTap:    { id, hero in store.send(.recentTapped(id, hero)) },
                    onCardDelete: { store.send(.deleteTapped($0)) },
                    onCardToggleFavorite: { store.send(.favoriteToggled($0)) }
                )

            case .empty:
                SearchEmptyResultView(
                    selectedIntent: store.selectedIntent,
                    onIntent:    { store.send(.intentChipTapped($0)) },
                    onAskMochi:  { store.send(.askMochiTapped) },
                    onRetryAll:  { store.send(.retryAllTapped) }
                )
            }
        }
        .riseIn(hasEntered, index: 0)
    }
}

// MARK: - Recent chip (최근 검색어 칩 — 검색바 아래 한 줄용 컴팩트)

private struct RecentChip: View {
    let term: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(term)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textPrimary.opacity(0.84))
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Capsule().fill(SearchD5.Palette.card))
                .overlay(Capsule().stroke(SearchD5.Palette.cardBorder, lineWidth: 1))
                .shadow(color: SearchD5.Palette.cardShadow, radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}
