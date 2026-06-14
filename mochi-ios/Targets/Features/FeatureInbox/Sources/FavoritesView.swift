import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

/// 즐겨찾기 화면 — 모찌가 "중요"로 표시된 기록을 다시 꺼내 보여준다.
/// 홈의 RecentMochiCard 를 2열 그리드로 재사용(가로 스크롤 카드와 같은 시각 언어). 항목 탭 → 공용 상세.
public struct FavoritesView: View {
    @Bindable public var store: StoreOf<FavoritesFeature>

    public init(store: StoreOf<FavoritesFeature>) { self.store = store }

    private let columns = [
        GridItem(.flexible(), spacing: HomeDesign.Spacing.md),
        GridItem(.flexible(), spacing: HomeDesign.Spacing.md),
    ]

    public var body: some View {
        ScrollView {
            if store.items.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: HomeDesign.Spacing.lg) {
                    ForEach(store.items) { mochiItem in
                        RecentMochiCard(
                            mochiItem: mochiItem,
                            onTap: { hero in store.send(.mochiItemTapped(mochiItem.id, hero: hero)) },
                            onDelete: { store.send(.deleteTapped(mochiItem.id)) }
                        )
                    }
                }
                .padding(HomeDesign.Spacing.lg)
            }
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .navigationTitle("즐겨찾기")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.onAppear) }
    }

    private var emptyState: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            Image(systemName: "star")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(HomeDesign.Color.purple400)
            Text("즐겨찾기한 기록이 없어요")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            Text("기록 상세나 검색에서 별을 눌러 두면\n여기서 모아 볼 수 있어요.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }
}
