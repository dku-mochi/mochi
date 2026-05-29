import SwiftUI

/// 시안의 보라색 채움 라운드 CTA 버튼.
///
/// LoginView 의 Apple/Google 버튼과 톤이 다르지만 (시안 의도) — 온보딩은 한 가지 행동만
/// 강조하는 단일 primary CTA 이므로 채움색·드롭섀도우가 더 강하다.
struct OnboardingButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(OnboardingTheme.primary)
                        .shadow(color: OnboardingTheme.primaryShadow, radius: 14, x: 0, y: 8)
                )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(title))
    }
}

/// 누름 시 살짝 축소 — TCA effect 가 끼지 않는 순수 시각 피드백.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#if DEBUG
#Preview {
    VStack {
        OnboardingButton(title: "다음") {}
        OnboardingButton(title: "단축어 등록하기") {}
    }
    .padding()
    .background(OnboardingTheme.backgroundGradient)
}
#endif
