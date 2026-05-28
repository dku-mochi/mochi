import SwiftUI

/// 시안의 "1  • • • •  5" 형태 페이지 인디케이터.
///
/// 좌측에 현재 페이지 번호, 가운데에 4개의 점 (현재 페이지 점만 채워짐),
/// 우측에 총 단계 수 (`OnboardingPage.totalSteps`) 를 표시한다.
struct PageIndicator: View {
    let current: Int   // 0-based
    let visibleCount: Int  // 점 개수 — 실제 페이지 수
    let total: Int     // 우측 라벨에 표시할 총 단계 (시안 = 5)

    var body: some View {
        HStack(spacing: 10) {
            label("\(current + 1)")

            HStack(spacing: 6) {
                ForEach(0..<visibleCount, id: \.self) { i in
                    Circle()
                        .fill(i == current ? OnboardingTheme.indicatorOn : OnboardingTheme.indicatorOff)
                        .frame(width: i == current ? 8 : 6, height: i == current ? 8 : 6)
                        .animation(.easeInOut(duration: 0.2), value: current)
                }
            }

            label("\(total)")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(current + 1) / \(total) 단계"))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(OnboardingTheme.mutedTextColor)
            .monospacedDigit()
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 24) {
        PageIndicator(current: 0, visibleCount: 4, total: 5)
        PageIndicator(current: 1, visibleCount: 4, total: 5)
        PageIndicator(current: 2, visibleCount: 4, total: 5)
        PageIndicator(current: 3, visibleCount: 4, total: 5)
    }
    .padding()
    .background(OnboardingTheme.backgroundGradient)
}
#endif
