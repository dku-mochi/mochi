import SwiftUI

/// 2페이지 — 백탭 안내.
///
/// 합성 (z 순):
/// 1. 아이폰 뒷면 (`iphone_back`) — 중앙, 살짝 좌측 기울임. 크기·위치 고정.
/// 2. 모찌 (`mochi-jump-shadow`) — **정적**. 우상단에서 항상 같은 위치/크기로 노출.
///    (이전 등장 애니메이션은 시선 분산이라 제거 — 손가락 탭 모션이 학습 포인트)
/// 3. 손가락 (`hand_tap`) — 손가락 끝이 아이폰 뒷면 중앙을 조준. -12° 회전.
///
/// **애니메이션 루프**: idle → tap1↓ → tap1↑ → tap2↓ → tap2↑(긴 정지) → idle.
struct BackTapPage: View {
    var body: some View {
        OnboardingPageScaffold(
            title: OnboardingPage.backTap.title,
            subtitle: OnboardingPage.backTap.subtitle
        ) {
            BackTapHero()
        }
    }
}

// MARK: - Phase

private enum TapPhase {
    case idle
    case tap1Down
    case tap1Up
    case tap2Down
    case tap2Up

    /// 손가락 Y 변위 (normalized). 음수 = 폰 쪽으로 위로 이동.
    var fingerLift: CGFloat {
        switch self {
        case .tap1Down, .tap2Down: return -1
        default: return 0
        }
    }
}

// MARK: - Hero

private struct BackTapHero: View {
    @State private var phase: TapPhase = .idle

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                phoneLayer(side: side)
                mochiLayer(side: side)
                handLayer(side: side)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task { await runLoop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("아이폰 뒷면을 두 번 탭하면 모찌가 나타나는 모습"))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Layers

    /// iPhone 은 좌측으로 이동시켜 우측에 모찌 공간을 확보.
    private func phoneLayer(side: CGFloat) -> some View {
        Image("iphone_back")
            .resizable()
            .scaledToFit()
            .frame(width: side * 0.78)
            .rotationEffect(.degrees(-4))
            .offset(x: -side * 0.20)
            .shadow(color: Color.black.opacity(0.12), radius: 30, x: 0, y: 20)
    }

    /// 모찌는 우상단 — 정적. iPhone/손과 겹치지 않게 x +30%, y -22%.
    /// (모찌 0.74 기준 시각 좌측 ≈ +0% 로 iPhone 우측 ≈ -0.5% 와 거의 맞닿게 배치 — 캐릭터
    /// 비중을 키우되 폰과 겹치지 않는 최대 사이즈.)
    private func mochiLayer(side: CGFloat) -> some View {
        Image("mochi-jump-shadow")
            .resizable()
            .scaledToFit()
            .frame(width: side * 0.74)
            .offset(x: side * 0.30, y: -side * 0.22)
    }

    /// 손은 폰 중심 (x: -20%) 보다 +7% 우측에 배치 — -12° 회전으로 손가락 끝이 좌상단으로
    /// 변위되어 결과적으로 폰 뒷면 중앙을 조준. 탭 모션 시 전체가 위로 ~7% 이동.
    private func handLayer(side: CGFloat) -> some View {
        Image("hand_tap")
            .resizable()
            .scaledToFit()
            .frame(width: side * 0.60)
            .rotationEffect(.degrees(-12))
            .offset(
                x: -side * 0.13,
                y: side * 0.26 + side * 0.07 * phase.fingerLift
            )
    }

    // MARK: Loop

    /// 더블탭 → 긴 정지 → 다음 루프. 실제 iOS 더블탭 리듬보다 느리지만, 온보딩 시연은
    /// 인지 가능성을 우선하므로 모든 보간을 easeInOut 으로 부드럽게 둔다.
    private func runLoop() async {
        // 진입 페이드
        withAnimation(.easeInOut(duration: 0.45)) { phase = .idle }
        try? await Task.sleep(for: .milliseconds(700))

        while !Task.isCancelled {
            // Tap 1
            withAnimation(.easeInOut(duration: 0.20)) { phase = .tap1Down }
            try? await Task.sleep(for: .milliseconds(210))

            withAnimation(.easeInOut(duration: 0.22)) { phase = .tap1Up }
            try? await Task.sleep(for: .milliseconds(220))

            // Tap 2
            withAnimation(.easeInOut(duration: 0.20)) { phase = .tap2Down }
            try? await Task.sleep(for: .milliseconds(210))

            // 두 탭 끝 — 긴 정지로 사용자가 동작을 인지하게 함
            withAnimation(.easeInOut(duration: 0.24)) { phase = .tap2Up }
            try? await Task.sleep(for: .milliseconds(1200))

            // 다음 루프 준비
            withAnimation(.easeInOut(duration: 0.4)) { phase = .idle }
            try? await Task.sleep(for: .milliseconds(550))
        }
    }
}

#if DEBUG
#Preview {
    BackTapPage()
        .background(OnboardingTheme.backgroundGradient.ignoresSafeArea())
}
#endif
