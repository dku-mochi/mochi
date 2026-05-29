import SwiftUI

/// 3페이지 — 공유 시트 안내.
///
/// 자산 `mochi-share` 는 YouTube · Instagram · Safari 아이콘 + 말풍선 + 공유 아이콘을
/// 든 모찌까지 한 장에 합성되어 있어 단일 Image 로 헤로 표현. 카피가 짧으므로 이미지가
/// 페이지의 주연.
struct SharePage: View {
    var body: some View {
        OnboardingPageScaffold(
            title: OnboardingPage.share.title,
            subtitle: OnboardingPage.share.subtitle
        ) {
            Image("mochi-share")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 320, maxHeight: 320)
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
#Preview {
    SharePage()
        .background(OnboardingTheme.backgroundGradient.ignoresSafeArea())
}
#endif
