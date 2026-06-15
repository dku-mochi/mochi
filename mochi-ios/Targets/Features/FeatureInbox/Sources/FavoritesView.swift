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
                // 첫 로드 중에는 "없음"을 단정하지 않고 skeleton 으로 기다린다(홈 recentSection 과 같은 규약) —
                // 진입 직후 빈 상태가 깜빡 떴다 사라지면 신뢰감이 깎인다.
                if store.isLoading {
                    skeletonGrid
                } else {
                    emptyState
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: HomeDesign.Spacing.lg) {
                    ForEach(store.items) { mochiItem in
                        RecentMochiCard(
                            mochiItem: mochiItem,
                            onTap: { hero in store.send(.mochiItemTapped(mochiItem.id, hero: hero)) },
                            onDelete: { store.send(.deleteTapped(mochiItem.id)) },
                            // 이 화면은 전부 즐겨찾기라 배지가 중복 노출 → 끈다.
                            showsFavoriteBadge: false
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

    /// 첫 로드 placeholder — 카드 자리만 잡아 "없음"이 깜빡이지 않게 한다(내용 없는 정적 회색 카드).
    private var skeletonGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.surface)
                    .frame(height: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                            .stroke(HomeDesign.Color.border, lineWidth: 1)
                    )
            }
        }
        .padding(HomeDesign.Spacing.lg)
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
