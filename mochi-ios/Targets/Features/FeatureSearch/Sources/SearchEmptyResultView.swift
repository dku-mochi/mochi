import SwiftUI
import DesignSystem

/// 검색 결과 0 화면 (.empty phase).
///
/// 구조: 공용 필터 바(종류 + 카테고리 — idle/결과와 동일) + 모찌(?) + 메시지 +
/// CTA(모찌에게 물어보기 — 채팅 의미 검색으로) + 고스트(필터 걸렸을 때만 "전체에서 다시 찾기").
struct SearchEmptyResultView: View {
    let typeFilter: SearchD5.TypeFilter
    let categories: [String]
    let selectedCategory: String?
    /// 종류·카테고리 중 하나라도 걸려 있으면 "전체에서 다시 찾기" 고스트 노출.
    let isFiltered: Bool
    let onTypeFilter: (SearchD5.TypeFilter) -> Void
    let onCategory: (String?) -> Void
    let onAskMochi: () -> Void
    let onRetryAll: () -> Void

    /// 마스코트 → 메시지 → CTA 순서로 떠오르는 내부 시차 — 홈 `riseIn` 패턴 재사용.
    @State private var hasEntered = false

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
                VStack(spacing: 0) {
                    mascot
                        .padding(.top, 60)
                        .padding(.bottom, 28)
                        .riseIn(hasEntered, index: 0)

                    headings
                        .padding(.bottom, 36)
                        .riseIn(hasEntered, index: 1)

                    ctas
                        .padding(.horizontal, SearchD5.Sizes.pageH)
                        .padding(.bottom, 16)
                        .riseIn(hasEntered, index: 2)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
        .onAppear { hasEntered = true }
    }

    // MARK: - 모찌(?) + halo

    private var mascot: some View {
        ZStack {
            Circle()
                .fill(SearchD5.Palette.primaryPale)
                .frame(width: SearchD5.Sizes.emptyMascotSize - 30,
                       height: SearchD5.Sizes.emptyMascotSize - 30)
                .blur(radius: 24)
                .opacity(0.55)
            FloatingMascot(imageName: "mochi-question", size: SearchD5.Sizes.emptyMascotSize)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Headings

    private var headings: some View {
        VStack(spacing: 8) {
            Text("찾는 모찌가 없어요")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(SearchD5.Palette.textPrimary)
            Text("모찌에게 물어보면 기억의 의미까지 더듬어 찾아드려요")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textSecondary)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - CTAs

    private var ctas: some View {
        VStack(spacing: 12) {
            Button(action: onAskMochi) {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("모찌에게 물어보기")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .tracking(-0.3)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: SearchD5.Sizes.ctaButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: SearchD5.Sizes.ctaButtonRadius, style: .continuous)
                        .fill(SearchD5.Palette.ctaGradient)
                )
                .shadow(color: SearchD5.Palette.primary.opacity(0.28), radius: 14, x: 0, y: 8)
            }
            .buttonStyle(PressableStyle())

            // 종류·카테고리로 좁혀서 0 인 경우에만 — 필터 풀고 전체에서 재검색.
            if isFiltered {
                Button(action: onRetryAll) {
                    Text("전체에서 다시 찾기")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .tracking(-0.3)
                        .foregroundStyle(SearchD5.Palette.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: SearchD5.Sizes.ctaButtonHeight - 2)
                        .background(
                            RoundedRectangle(cornerRadius: SearchD5.Sizes.ctaButtonRadius, style: .continuous)
                                .fill(SearchD5.Palette.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: SearchD5.Sizes.ctaButtonRadius, style: .continuous)
                                .stroke(SearchD5.Palette.cardBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}
// EmptyCTAPress 삭제(2026-07-10) — Reduce Motion 을 존중하는 공용 PressableStyle 로 통일.
