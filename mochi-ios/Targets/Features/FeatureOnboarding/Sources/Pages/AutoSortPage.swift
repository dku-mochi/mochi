import SwiftUI

/// 4페이지 — AI 자동 분류 안내.
///
/// 시안 구성: 4-Intent 아이콘 (일정·할 일·지식·기록) 한 줄 + 그 아래 큰 모찌.
/// 라벨 텍스트·화살표 없이 캐릭터 비중을 키운 단순 구성 — 타이틀/서브가 이미
/// "뭐든지 캡처만 하면 / 일정, 할 일, 지식, 기록으로 자동 분류" 를 설명하므로
/// hero 영역은 시각 신호만 담당.
///
/// 자산: clay-style 3D PNG (`cat-calendar` / `cat-checklist` / `cat-book` /
/// `cat-document`) + `mochi2` (좌측 손 든 모찌, 캐릭터 정면).
struct AutoSortPage: View {
    /// PRODUCT.md §5 4-Intent 순서 (일정·할 일·지식·기록) 와 일치.
    private let iconAssets = ["cat-calendar", "cat-checklist", "cat-book", "cat-document"]

    var body: some View {
        OnboardingPageScaffold(
            title: OnboardingPage.autoSort.title,
            subtitle: OnboardingPage.autoSort.subtitle
        ) {
            hero
        }
    }

    private var hero: some View {
        VStack(spacing: 24) {
            // 아이콘 셀은 1:1 비율 유지하며 maxWidth 100 까지 균등 분배.
            // fixed size 면 좁은 디바이스에서 잘릴 위험 → 폭에 맞춰 자동 축소.
            HStack(spacing: 10) {
                ForEach(iconAssets, id: \.self) { asset in
                    Image(asset)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 100)
                }
            }
            .frame(maxWidth: .infinity)

            Image("mochi2")
                .resizable()
                .scaledToFit()
                .frame(width: 220)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("일정, 할 일, 지식, 기록 네 가지로 자동 분류"))
    }
}

#if DEBUG
#Preview {
    AutoSortPage()
        .background(OnboardingTheme.backgroundGradient.ignoresSafeArea())
}
#endif
