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

    /// 화면이 그리는 phase — 포커스 진입은 store 왕복을 기다리지 않고 FocusState 로 즉시 전환.
    /// (탭 → focused 화면 전환이 reducer 응답 대기로 늦어 두 번 탭하게 되던 문제)
    private var displayPhase: SearchFeature.State.Phase {
        if isSearchFocused && queryText.isEmpty && store.query.isEmpty { return .focused }
        return store.phase
    }

    public var body: some View {
        ZStack(alignment: .top) {
            SearchD5.Palette.bgCream.ignoresSafeArea()

            // 포커스 화면에만 워시 깔기
            if displayPhase == .focused {
                VStack(spacing: 0) {
                    SearchD5.Palette.headerWash
                        .frame(height: 360)
                        .opacity(0.55)
                    Spacer()
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, SearchD5.Sizes.pageH)
                    .padding(.top, 16)
                    .padding(.bottom, 14)

                phaseBody
            }
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
            // 키보드 띄울 때만 focused phase 진입.
            // ✓ 또는 스와이프로 키보드만 dismiss 될 때는 state.isFocused 유지 → focused 화면 그대로.
            // .idle 복귀는 명시 action (quickFilter / recentSearch / clearFilters / 탭 reselect) 으로만.
            if newValue {
                store.send(.searchBarFocused(true))
            }
        }
        .onChange(of: store.isFocused) { _, newValue in
            // reducer 가 isFocused 를 false 로 바꿀 때(빠른검색 칩 등) FocusState 도 sync.
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

            // query 가 있거나 focused 상태일 때 X 활성 — focused 에서 .idle 그리드로 돌아가는 affordance.
            if !queryText.isEmpty || isSearchFocused || store.isFocused {
                Button {
                    queryText = ""
                    store.send(.clearFiltersTapped)
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(SearchD5.Palette.textTertiary)
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

    // MARK: - Body (phase 4 분기)

    @ViewBuilder
    private var phaseBody: some View {
        Group {
            switch displayPhase {
            case .idle:
                SearchDefaultView(
                    items: store.filteredItems,
                    typeFilter: store.typeFilter,
                    onTypeFilter: { store.send(.typeFilterTapped($0)) },
                    onCardTap:    { id, hero in store.send(.recentTapped(id, hero)) },
                    onCardDelete: { store.send(.deleteTapped($0)) },
                    onRefresh:    { await store.send(.refreshPulled).finish() }
                )

            case .focused:
                SearchFocusedView(
                    recentSearches: store.recentSearches,
                    onRecent:       { store.send(.recentSearchTapped($0)) },
                    onRemoveRecent: { store.send(.removeRecentSearchTapped($0)) },
                    onClearRecents: { store.send(.clearRecentSearchesTapped) },
                    onQuickFilter:  { store.send(.quickFilterTapped($0)) }
                )

            case .results:
                SearchResultsView(
                    query: store.query,
                    results: store.results,
                    selectedIntent: store.selectedIntent,
                    isSemanticSearching: store.isSemanticSearching,
                    onIntent:     { store.send(.intentChipTapped($0)) },
                    onCardTap:    { id, hero in store.send(.recentTapped(id, hero)) },
                    onCardDelete: { store.send(.deleteTapped($0)) }
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
