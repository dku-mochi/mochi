import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 결과 화면 (.results phase).
///
/// 구조: 공용 필터 바(종류 + 카테고리 — idle 과 동일) + 결과 요약 + 2col 그리드.
/// 검색을 시작해도 상단 필터가 그대로라 단절감이 없고, 고른 카테고리 안에서만 결과가 남는다.
struct SearchResultsView: View {
    let query: String
    let results: [SearchResult]
    let typeFilter: SearchD5.TypeFilter
    let categories: [String]
    let selectedCategory: String?
    let isSemanticSearching: Bool
    let onTypeFilter: (SearchD5.TypeFilter) -> Void
    let onCategory: (String?) -> Void
    let onCardTap: (MochiItem.ID, HeroSourceFrames) -> Void
    let onCardDelete: (MochiItem.ID) -> Void
    let onCardToggleFavorite: (MochiItem.ID) -> Void

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

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                        .padding(.horizontal, SearchD5.Sizes.pageH)

                    // 카드 높이 가변(2:3 이미지 ~275 / 텍스트 타일 138) — 기본 그리드와 동일 masonry.
                    HStack(alignment: .top, spacing: SearchD5.Sizes.gridGap) {
                        masonryColumn(columns.left)
                        masonryColumn(columns.right)
                    }
                    // 모자이크 그리드 — 좌우는 칩(pageH 14)보다 살짝 좁은 gridPageH 10.
                    .padding(.horizontal, SearchD5.Sizes.gridPageH)
                }
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func masonryColumn(_ columnResults: [SearchResult]) -> some View {
        LazyVStack(spacing: SearchD5.Sizes.gridGap) {
            ForEach(columnResults) { result in
                SearchGridCard(
                    item: result.item,
                    titleHighlights: result.titleHighlights,
                    summaryHighlights: result.summaryHighlights,
                    isSemantic: result.isSemantic,
                    onTap: { hero in onCardTap(result.item.id, hero) },
                    onDelete: { onCardDelete(result.item.id) },
                    onToggleFavorite: { onCardToggleFavorite(result.item.id) }
                )
            }
        }
    }

    /// 예상 높이 기준 좌우 균형 분배 — 짧은 column 에 다음 카드를 넣는다.
    private var columns: (left: [SearchResult], right: [SearchResult]) {
        var left: [SearchResult] = [], right: [SearchResult] = []
        var leftH: CGFloat = 0, rightH: CGFloat = 0
        for result in results {
            let h = SearchGridCard.estimatedHeight(for: result.item)
            if leftH <= rightH {
                left.append(result); leftH += h
            } else {
                right.append(result); rightH += h
            }
        }
        return (left, right)
    }

    // MARK: - 결과 요약

    private var summary: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(SearchD5.Palette.primary)
                // 의미 검색이 도는 동안 sparkles 가 실제로 반짝인다 — 스피너와 같은 말을 아이콘이 한 번 더.
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isSemanticSearching)
            Text(summaryText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                // 의미 검색이 결과를 보태면 N 이 점프한다 — 숫자만 굴려서(numericText) 변화를 보여준다.
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: results.count)
            if isSemanticSearching {
                ProgressView()
                    .controlSize(.mini)
                Text("더 찾는 중")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textTertiary)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        // "더 찾는 중" 이 뚝 사라지지 않게 — 종료는 등장보다 조용히.
        .animation(.easeOut(duration: 0.2), value: isSemanticSearching)
    }

    private var summaryText: AttributedString {
        var s = AttributedString()
        var head = AttributedString(query)
        head.font = .system(size: 14, weight: .semibold, design: .rounded)
        head.foregroundColor = SearchD5.Palette.textPrimary
        s.append(head)

        // 카테고리는 활성 칩으로 이미 보이므로 요약엔 반복하지 않는다 — "[query]과 관련된 모찌 N개".
        var tail = AttributedString("과 관련된 모찌 ")
        tail.foregroundColor = SearchD5.Palette.textSecondary
        s.append(tail)

        var count = AttributedString("\(results.count)개")
        // 자릿수 변해도 폭이 안 흔들리게 — numericText 롤링과 한 세트.
        count.font = Font.system(size: 14, weight: .bold).monospacedDigit()
        count.foregroundColor = SearchD5.Palette.primaryDeep
        s.append(count)
        return s
    }
}
