import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 결과 화면 (.results phase) — 새 시안.
///
/// 구조: intent 필터칩 row (전체/일정/할일/지식/기록) + 결과 요약 + 2col 그리드.
struct SearchResultsView: View {
    let query: String
    let results: [SearchResult]
    let selectedIntent: Intent?
    let isSemanticSearching: Bool
    let onIntent: (Intent?) -> Void
    let onCardTap: (MochiItem.ID, HeroSourceFrames) -> Void
    let onCardDelete: (MochiItem.ID) -> Void
    let onCardToggleFavorite: (MochiItem.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            IntentFilterChipsRow(selectedIntent: selectedIntent, onTap: onIntent)
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
                .scrollTransition(.animated(.easeOut(duration: 0.25))) { content, phase in
                    content
                        .opacity(phase.isIdentity ? 1 : 0.55)
                        .scaleEffect(phase.isIdentity ? 1 : 0.96)
                }
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
            Text(summaryText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if isSemanticSearching {
                ProgressView()
                    .controlSize(.mini)
                Text("더 찾는 중")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var summaryText: AttributedString {
        var s = AttributedString()
        var head = AttributedString(query)
        head.font = .system(size: 14, weight: .semibold, design: .rounded)
        head.foregroundColor = SearchD5.Palette.textPrimary
        s.append(head)

        // Intent 가 걸려 있으면 문맥을 더해 "[query] · [intent label] N개" 형태로 — 그 외엔 기존 "[query]과 관련된 모찌 N개".
        if let intent = selectedIntent {
            var sep = AttributedString(" · ")
            sep.foregroundColor = SearchD5.Palette.textTertiary
            s.append(sep)
            var intentLabel = AttributedString(SearchD5.IntentColor.label(intent))
            intentLabel.font = .system(size: 14, weight: .semibold, design: .rounded)
            intentLabel.foregroundColor = SearchD5.IntentColor.fg(intent)
            s.append(intentLabel)
            var space = AttributedString(" ")
            space.foregroundColor = SearchD5.Palette.textSecondary
            s.append(space)
        } else {
            var tail = AttributedString("과 관련된 모찌 ")
            tail.foregroundColor = SearchD5.Palette.textSecondary
            s.append(tail)
        }

        var count = AttributedString("\(results.count)개")
        count.font = .system(size: 14, weight: .bold)
        count.foregroundColor = SearchD5.Palette.primaryDeep
        s.append(count)
        return s
    }
}

// MARK: - Intent filter chips (전체 + 4 intent — 결과/빈결과 공용)

struct IntentFilterChipsRow: View {
    let selectedIntent: Intent?
    let onTap: (Intent?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                IntentChip(
                    label: "전체",
                    systemImage: "square.grid.2x2",
                    bg: SearchD5.Palette.primaryPale,
                    fg: SearchD5.Palette.primaryDeep,
                    isActive: selectedIntent == nil
                ) { onTap(nil) }

                ForEach(Intent.allCases, id: \.self) { intent in
                    IntentChip(
                        label: SearchD5.IntentColor.label(intent),
                        systemImage: SearchD5.IntentColor.systemImage(intent),
                        bg: SearchD5.IntentColor.bg(intent),
                        fg: SearchD5.IntentColor.fg(intent),
                        isActive: selectedIntent == intent
                    ) { onTap(intent) }
                }
            }
            .padding(.horizontal, SearchD5.Sizes.pageH)
            .padding(.vertical, 4)
        }
    }
}

private struct IntentChip: View {
    let label: String
    let systemImage: String
    let bg: Color
    let fg: Color
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tracking(-0.3)
            }
            .padding(.horizontal, 9)
            .frame(height: SearchD5.Sizes.filterChipHeight)
            .foregroundStyle(isActive ? fg : SearchD5.Palette.textPrimary.opacity(0.82))
            .background(Capsule().fill(isActive ? bg : SearchD5.Palette.card))
            .overlay(
                Capsule().stroke(
                    isActive ? fg.opacity(0.55) : SearchD5.Palette.cardBorder,
                    lineWidth: isActive ? 1.2 : 1
                )
            )
            .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) 필터")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
