import SwiftUI

/// 1페이지 — 모찌가 자기 자신을 소개. 자산 `mochi-hello` 가 캐릭터+하트 말풍선까지
/// 한 장에 포함하므로 별도 레이어 합성 없이 단일 이미지로 표현한다.
struct IntroPage: View {
    var body: some View {
        OnboardingPageScaffold(
            title: OnboardingPage.intro.title,
            subtitle: OnboardingPage.intro.subtitle
        ) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                // 캐릭터 몸통이 캔버스의 ~0.61 폭(나머지는 하트 말풍선·여백)이라, share 와 몸통
                // 크기를 맞추려면 프레임을 키워야 한다. 300 → 몸통 ~183pt (share 235 와 동일).
                .frame(maxWidth: 300, maxHeight: 300)
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
#Preview {
    IntroPage()
        .background(OnboardingTheme.backgroundGradient.ignoresSafeArea())
}
#endif
