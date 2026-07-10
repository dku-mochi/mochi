import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 탭 *기본* 화면 (.idle phase) — 검색바 빈 상태 + 포커스 X.
///
/// 필터: 타입(전체/링크/스크린샷/메모) 드롭다운 + 카테고리(주간 리포트 정규화 category) 칩 행.
/// 둘은 AND 로 동시 적용(상위 SearchFeature.filteredItems). 2col 모자이크 그리드.
struct SearchDefaultView: View {
    let items: [MochiItem]
    let typeFilter: SearchD5.TypeFilter
    let onTypeFilter: (SearchD5.TypeFilter) -> Void
    /// 카테고리 칩 — 전체 기록의 정규화 category 많은 순. nil = 전체.
    let categories: [String]
    let selectedCategory: String?
    let onCategory: (String?) -> Void
    let onCardTap: (MochiItem.ID, HeroSourceFrames) -> Void
    let onCardDelete: (MochiItem.ID) -> Void
    let onCardToggleFavorite: (MochiItem.ID) -> Void
    let onRefresh: () async -> Void

    /// 빈 상태 마스코트 → 제목 → 부제 시차 등장 — empty 화면과 같은 `riseIn` 패턴.
    @State private var emptyEntered = false

    var body: some View {
        VStack(spacing: 0) {
            SearchFilterBar(
                typeFilter: typeFilter,
                onTypeFilter: onTypeFilter,
                categories: categories,
                selectedCategory: selectedCategory,
                onCategory: onCategory
            )
            .padding(.top, 10)
            .padding(.bottom, 6)

            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // 카드 높이가 type 별 가변(2:3 이미지 ~275 / 텍스트 타일 138)이라
                    // LazyVGrid(행 정렬) 대신 좌우 독립 column 의 masonry — 높이 균형 분배.
                    HStack(alignment: .top, spacing: SearchD5.Sizes.gridGap) {
                        masonryColumn(columns.left)
                        masonryColumn(columns.right)
                    }
                    // 모자이크 그리드 — 좌우는 칩(pageH 14)보다 살짝 좁은 gridPageH 10.
                    .padding(.horizontal, SearchD5.Sizes.gridPageH)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .refreshable { await onRefresh() }
            }
        }
    }

    private func masonryColumn(_ columnItems: [MochiItem]) -> some View {
        LazyVStack(spacing: SearchD5.Sizes.gridGap) {
            ForEach(columnItems) { item in
                SearchGridCard(
                    item: item,
                    onTap: { hero in onCardTap(item.id, hero) },
                    onDelete: { onCardDelete(item.id) },
                    onToggleFavorite: { onCardToggleFavorite(item.id) }
                )
            }
        }
    }

    /// 예상 높이 기준 좌우 균형 분배 — 짧은 column 에 다음 카드를 넣는다.
    private var columns: (left: [MochiItem], right: [MochiItem]) {
        var left: [MochiItem] = [], right: [MochiItem] = []
        var leftH: CGFloat = 0, rightH: CGFloat = 0
        for item in items {
            let h = SearchGridCard.estimatedHeight(for: item)
            if leftH <= rightH {
                left.append(item); leftH += h
            } else {
                right.append(item); rightH += h
            }
        }
        return (left, right)
    }

    // MARK: - 빈 상태 (저장된 모찌 0 — 필터 결과 0 도 동일 처리)

    /// 전체 필터에서 비면 "아직 저장 전", 특정 필터에서 비면 "이 종류 없음" 문구로 구분.
    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            FloatingMascot(imageName: "mochi-question", size: 150)
                .padding(.bottom, 20)
                .riseIn(emptyEntered, index: 0)
            Text(typeFilter == .all ? "아직 저장된 모찌가 없어요" : "\(typeFilter.label) 모찌가 없어요")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .tracking(-0.4)
                .foregroundStyle(SearchD5.Palette.textPrimary)
                .padding(.bottom, 6)
                .riseIn(emptyEntered, index: 1)
            Text(typeFilter == .all
                 ? "스크린샷·링크·메모를 모찌에게 보내면\n여기에 차곡차곡 모여요"
                 : "다른 종류에서 찾아보세요")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .tracking(-0.2)
                .lineSpacing(3)
                .foregroundStyle(SearchD5.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .riseIn(emptyEntered, index: 2)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear { emptyEntered = true }
    }
}
