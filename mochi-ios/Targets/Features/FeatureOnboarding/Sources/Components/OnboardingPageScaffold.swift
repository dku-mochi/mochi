import SwiftUI

/// 4 페이지 공통 레이아웃 — 상단 타이틀/서브, 중앙 히어로, 인디케이터 + CTA 푸터.
///
/// 페이지마다 일러스트 구성만 다르고 나머지는 동일하므로 ViewBuilder 슬롯으로 빼낸다.
struct OnboardingPageScaffold<Hero: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let hero: () -> Hero

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // MARK: Copy — 글씨가 한 박자씩 떠오른다 (제목 → 부제).
            VStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(OnboardingTheme.titleColor)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .onboardingEnter(0, appeared, reduceMotion: reduceMotion)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(OnboardingTheme.subtitleColor)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .onboardingEnter(1, appeared, reduceMotion: reduceMotion)
                }
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 32)

            // MARK: Hero illustration — 글씨 뒤에 등장.
            hero()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .onboardingEnter(2, appeared, reduceMotion: reduceMotion)

            Spacer(minLength: 24)
        }
        .onAppear { appeared = true }
    }
}
