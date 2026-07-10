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
                    // 검색바가 반 박자 먼저(index 0), 콘텐츠가 따라(index 1) — 한 덩어리 페이드보다 살아 있는 진입.
                    .riseIn(hasEntered, index: 0)

                if showsRecentChips {
                    recentChipsRow
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                phaseBody
                    // 항상 떠 있던 ✓ 바 제거(2026-06-17) 보상 — 콘텐츠 영역 탭으로 키보드 dismiss.
                    // simultaneousGesture 라 카드·칩·드롭다운 탭은 그대로 통과(탭 + dismiss 동시).
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            if isSearchFocused { isSearchFocused = false }
                        }
                    )
            }
            .animation(.easeInOut(duration: 0.18), value: showsRecentChips)
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.light)
        // 결과가 손에 잡히는 순간(→results)만 soft 틱 — idle/empty 로 빠질 땐 무음 (실패에 진동은 소음).
        .sensoryFeedback(trigger: store.phase) { _, newPhase in
            newPhase == .results ? .impact(flexibility: .soft, intensity: 0.7) : nil
        }
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
        // 카드 height 고정(182/138) 레이아웃이라 무제한 확대는 잘림 — large 까지는 lineLimit 으로 안전.
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    // MARK: - 검색바

    private var searchBar: some View {
        HStack(spacing: 10) {
            // 텍스트(17)와 한 호흡으로 읽히도록 글래스는 18 — 22 는 텍스트를 압도했다.
            // 포커스 시 잉크 → 퍼플로 옮겨 입력 상태를 색으로 알린다.
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(isSearchFocused ? SearchD5.Palette.primary : SearchD5.Palette.textTertiary)

            ZStack(alignment: .leading) {
                if queryText.isEmpty {
                    // placeholder 와 TextField 폰트를 17 로 일치 — 타이핑 시작 때 글자가 리사이즈되며 튀던 현상 제거.
                    Text("기억나는 말로 찾아보세요")
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .foregroundStyle(SearchD5.Palette.placeholder)
                        .allowsHitTesting(false)
                }
                TextField("", text: $queryText)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                    .tint(SearchD5.Palette.primary)
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

            // query 가 있을 때만 X — 빈 상태의 키보드 dismiss 는 스크롤·return·콘텐츠 탭이 담당.
            if !queryText.isEmpty {
                Button {
                    queryText = ""
                    store.send(.clearFiltersTapped)
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(SearchD5.Palette.textTertiary)
                        // 아이콘은 그대로, 터치 영역만 44. trailing -8 로 끌어와 글래스(18pt inset)와 광학 대칭.
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .padding(.trailing, -8)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .padding(.leading, 18)
        // X 가 자체 hit-area(44)를 들고 있어, 있을 땐 trailing 여백을 줄여 아이콘이 가장자리에 붙지 않게.
        .padding(.trailing, queryText.isEmpty ? 18 : 4)
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
        // 포커스 시 잉크 그림자 → 브랜드 퍼플 halo — 색(아이콘·스트로크)과 빛이 같은 말을 한다.
        .shadow(color: isSearchFocused ? SearchD5.Palette.primary.opacity(0.22) : SearchD5.Palette.cardShadow.opacity(0.5),
                radius: isSearchFocused ? 16 : 10, x: 0, y: 6)
        .animation(.smooth(duration: 0.2), value: isSearchFocused)
        .animation(.snappy(duration: 0.22), value: queryText.isEmpty)
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
                    onTypeFilter: { store.send(.typeFilterTapped($0), animation: .smooth(duration: 0.3)) },
                    categories: store.availableCategories,
                    selectedCategory: store.selectedCategory,
                    onCategory: { store.send(.categoryTapped($0), animation: .smooth(duration: 0.3)) },
                    onCardTap:    { id, hero in store.send(.recentTapped(id, hero)) },
                    onCardDelete: { store.send(.deleteTapped($0)) },
                    onCardToggleFavorite: { store.send(.favoriteToggled($0)) },
                    onRefresh:    { await store.send(.refreshPulled).finish() }
                )

            case .results:
                SearchResultsView(
                    query: store.query,
                    results: store.results,
                    typeFilter: store.typeFilter,
                    categories: store.availableCategories,
                    selectedCategory: store.selectedCategory,
                    isSemanticSearching: store.isSemanticSearching,
                    onTypeFilter: { store.send(.typeFilterTapped($0), animation: .smooth(duration: 0.3)) },
                    onCategory:   { store.send(.categoryTapped($0), animation: .smooth(duration: 0.3)) },
                    onCardTap:    { id, hero in store.send(.recentTapped(id, hero)) },
                    onCardDelete: { store.send(.deleteTapped($0)) },
                    onCardToggleFavorite: { store.send(.favoriteToggled($0)) }
                )

            case .empty:
                SearchEmptyResultView(
                    typeFilter: store.typeFilter,
                    categories: store.availableCategories,
                    selectedCategory: store.selectedCategory,
                    isFiltered: store.typeFilter != .all || store.selectedCategory != nil,
                    onTypeFilter: { store.send(.typeFilterTapped($0), animation: .smooth(duration: 0.3)) },
                    onCategory:   { store.send(.categoryTapped($0), animation: .smooth(duration: 0.3)) },
                    onAskMochi:  { store.send(.askMochiTapped) },
                    onRetryAll:  { store.send(.retryAllTapped, animation: .smooth(duration: 0.3)) }
                )
            }
        }
        // phase 스위치(idle↔results↔empty)가 뚝 끊기지 않게 — 짧은 crossfade 하나면 충분하다.
        .animation(.easeInOut(duration: 0.22), value: store.phase)
        .riseIn(hasEntered, index: 1)
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
        // .plain 은 눌러도 무반응이었다 — 공용 press 스타일(스케일+딤, Reduce Motion 대응)로 손맛 통일.
        .buttonStyle(PressableStyle())
    }
}
