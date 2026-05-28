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
                .frame(maxWidth: 280, maxHeight: 280)
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
