import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 결과 0 화면 (.empty phase) — 새 시안 #36.
///
/// 구조: intent 필터칩 row + 모찌(?) + 메시지 + CTA(전체에서 다시 찾기) + 고스트(필터 초기화).
struct SearchEmptyResultView: View {
    let selectedIntent: Intent?
    let onIntent: (Intent?) -> Void
    let onRetryAll: () -> Void
    let onClearFilters: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            IntentFilterChipsRow(selectedIntent: selectedIntent, onTap: onIntent)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    mascot
                        .padding(.top, 60)
                        .padding(.bottom, 28)

                    headings
                        .padding(.bottom, 36)

                    ctas
                        .padding(.horizontal, SearchD5.Sizes.pageH)
                        .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
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
            Text("다른 단어로 찾아보거나 필터를 줄여보세요")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textSecondary)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - CTAs

    private var ctas: some View {
        VStack(spacing: 12) {
            Button(action: onRetryAll) {
                Text("전체에서 다시 찾기")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: SearchD5.Sizes.ctaButtonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: SearchD5.Sizes.ctaButtonRadius, style: .continuous)
                            .fill(SearchD5.Palette.ctaGradient)
                    )
                    .shadow(color: SearchD5.Palette.primary.opacity(0.28), radius: 14, x: 0, y: 8)
            }
            .buttonStyle(EmptyCTAPress())

            Button(action: onClearFilters) {
                Text("필터 초기화")
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
            .buttonStyle(EmptyCTAPress())
        }
    }
}

private struct EmptyCTAPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
