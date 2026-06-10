import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

public struct SearchView: View {
    @Bindable public var store: StoreOf<SearchFeature>
    @FocusState private var isSearchFocused: Bool
    /// 첫 진입 시 phaseBody 가 시차 두고 떠오르는 entrance — 홈·캘린더 `riseIn` 패턴.
    @State private var hasEntered: Bool = false

    public init(store: StoreOf<SearchFeature>) { self.store = store }

    public var body: some View {
        ZStack(alignment: .top) {
            SearchD5.Palette.bgCream.ignoresSafeArea()

            // 포커스 화면에만 워시 깔기
            if store.phase == .focused {
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
            hasEntered = true
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
        .dynamicTypeSize(.medium)
    }

    // MARK: - Keyboard dismiss bar (검색바 포커스 시 키보드 위 ✓)

    /// 키보드가 올라오면 시스템이 bottom safe area 를 키보드 위까지 올려주므로,
    /// `.safeAreaInset(edge: .bottom)` 에 둔 view 가 자동으로 키보드 위에 stick 된다.
    @ViewBuilder
    private var keyboardDismissBar: some View {
        if isSearchFocused {
            HStack(spacing: 0) {
                Spacer()
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 검색바

    private var searchBar: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(SearchD5.Palette.textTertiary)

            ZStack(alignment: .leading) {
                if store.query.isEmpty {
                    Text("기억나는 말로 찾아보세요")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(SearchD5.Palette.placeholder)
                        .allowsHitTesting(false)
                }
                TextField("", text: $store.query)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isSearchFocused)
                    .onSubmit { isSearchFocused = false }
            }

            // query 가 있거나 focused 상태일 때 X 활성 — focused 에서 .idle 그리드로 돌아가는 affordance.
            if !store.query.isEmpty || store.isFocused {
                Button {
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
            switch store.phase {
            case .idle:
                SearchDefaultView(
                    items: store.filteredItems,
                    typeFilter: store.typeFilter,
                    onTypeFilter: { store.send(.typeFilterTapped($0)) },
                    onCardTap:    { id, hero in store.send(.recentTapped(id, hero)) },
                    onCardDelete: { store.send(.deleteTapped($0)) }
                )

            case .focused:
                SearchFocusedView(
                    onRecent:       { store.send(.recentSearchTapped($0)) },
                    onClearRecents: { store.send(.clearRecentSearchesTapped) },
                    onQuickFilter:  { store.send(.quickFilterTapped($0)) }
                )

            case .results:
                SearchResultsView(
                    query: store.query,
                    results: store.results,
                    selectedIntent: store.selectedIntent,
                    onIntent:     { store.send(.intentChipTapped($0)) },
                    onCardTap:    { id, hero in store.send(.recentTapped(id, hero)) },
                    onCardDelete: { store.send(.deleteTapped($0)) }
                )

            case .empty:
                SearchEmptyResultView(
                    selectedIntent: store.selectedIntent,
                    onIntent:       { store.send(.intentChipTapped($0)) },
                    onRetryAll:     { store.send(.retryAllTapped) },
                    onClearFilters: { store.send(.clearFiltersTapped) }
                )
            }
        }
        .riseIn(hasEntered, index: 0)
    }
}
