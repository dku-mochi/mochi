import SwiftUI

/// 2페이지 — 백탭 안내.
///
/// 합성 (z 순):
/// 1. 아이폰 뒷면 (`iphone_back`) — 3/4 측면뷰. 자산 자체가 3D 회전을 포함하므로
///    rotation3DEffect 불필요. Apple 로고가 캔버스 살짝 좌측 중앙에 위치.
/// 2. 동심원 펄스 — 탭 시점에 Apple 로고 위치에서 발생 (2회).
/// 3. "1x"/"2x" 카운터 캡슐 — 손가락 좌상단, 탭 진행에 따라 단계 증가.
/// 4. 손가락 (`hand_tap`) — idle 에선 우하단 fade, approach 부터 Apple 로고 조준.
/// 5. 단축어 등록 카드 — 우측에서 spring 등장, 두 번째 탭 완료 후.
/// 6. Sparkle 입자 6개 — 카드 등장과 동시에 폰 주위 방사형 폭발.
///
/// **애니메이션 루프**: idle → approach → tap1↓↑ → tap2↓↑ → reveal → hold → reset.
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
    case approach
    case tap1Down
    case tap1Up
    case tap2Down
    case tap2Up
    case reveal
    case hold

    /// 손가락이 폰에 다가왔는지 (idle 에선 우하단 멀리, 그 외엔 Apple 로고 조준 위치).
    var fingerApproached: Bool {
        if case .idle = self { return false }
        return true
    }

    /// 손가락 Y 변위 (normalized, side 기준). 음수 = 폰 쪽으로 위.
    var fingerLift: CGFloat {
        switch self {
        case .tap1Down, .tap2Down: return -1
        default: return 0
        }
    }

    /// 손가락 활성도 (idle 에선 살짝 흐릿).
    var fingerOpacity: Double {
        switch self {
        case .idle: return 0.55
        default: return 1.0
        }
    }

    /// 탭 카운터 표시값 (0 이면 hidden).
    var tapCount: Int {
        switch self {
        case .idle, .approach: return 0
        case .tap1Down, .tap1Up: return 1
        case .tap2Down, .tap2Up, .reveal, .hold: return 2
        }
    }

    /// 카드/sparkle 등장 여부.
    var cardRevealed: Bool {
        switch self {
        case .reveal, .hold: return true
        default: return false
        }
    }
}

// MARK: - Hero

private struct BackTapHero: View {
    @State private var phase: TapPhase = .idle
    /// 펄스를 매 탭마다 새로 시작시키는 트리거. PulseRipple 가 onChange 감지.
    @State private var pulseTrigger: Int = 0

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                phoneLayer(side: side)
                PulseRipple(trigger: pulseTrigger, baseSize: side * 0.18)
                    .offset(appleLogoOffset(side: side))
                tapCounterLayer(side: side)
                handLayer(side: side)
                cardLayer(side: side)
                sparkleLayer(side: side)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task { await runLoop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("아이폰 뒷면을 두 번 탭하면 단축어가 등록되는 모습"))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// 자산은 그림자 없는 transparent RGBA. 회전 -30° 로 Apple 로고가 폰 중심 좌측에 보임.
    /// 자산이 `side * 1.0` 너비로 fit 되었을 때 Apple 로고의 hero-좌표 (캔버스 center 기준).
    /// 자산 캔버스 1024 기준 Apple 로고 ≈ (-89, +43) → normalized × 1.0 frame.
    private func appleLogoOffset(side: CGFloat) -> CGSize {
        CGSize(width: -side * 0.087, height: side * 0.042)
    }

    // MARK: Layers

    /// 폰 자산 + 코드로 합성한 ground shadow (자산 자체엔 그림자 없음).
    /// `.shadow` 는 alpha mask 기반이라 transparent 폰 윤곽을 그대로 따라감.
    /// 추가로 폰 발 밑에 더 진한 ellipse blur 를 깔아 "지면 접촉" 느낌을 강화.
    private func phoneLayer(side: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.16))
                .frame(width: side * 0.55, height: side * 0.06)
                .blur(radius: 16)
                .offset(y: side * 0.42)

            Image("iphone_back")
                .resizable()
                .scaledToFit()
                .frame(width: side * 1.0)
                .shadow(color: Color.black.opacity(0.13), radius: 22, x: 0, y: 12)
        }
    }

    /// "1x" / "2x" 카운터 캡슐 — Apple 로고 우상단에 floating.
    private func tapCounterLayer(side: CGFloat) -> some View {
        Text("\(phase.tapCount)x")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(OnboardingTheme.primary)
                    .shadow(color: OnboardingTheme.primaryShadow, radius: 6, x: 0, y: 3)
            )
            .scaleEffect(phase.tapCount == 2 ? 1.18 : 1.0)
            .opacity(phase.tapCount == 0 ? 0 : 1)
            .offset(x: side * 0.10, y: -side * 0.12)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: phase.tapCount)
    }

    /// 손가락 — 검지 끝이 Apple 로고를 조준. idle 에선 우하단 멀리 fade, approach 부터 진입.
    /// hand_tap 자산의 손가락 끝이 frame 상단 중앙 근처라, hand frame center 는
    /// Apple 로고에서 +Y `frame*0.4` 정도 (frame 절반 + 손목) 아래에 위치해야 닿음.
    private func handLayer(side: CGFloat) -> some View {
        let logo = appleLogoOffset(side: side)
        return Image("hand_tap")
            .resizable()
            .scaledToFit()
            .frame(width: side * 0.42)
            .rotationEffect(.degrees(-10))
            .opacity(phase.fingerOpacity)
            .offset(
                x: phase.fingerApproached ? logo.width + side * 0.034 : side * 0.32,
                y: (phase.fingerApproached ? logo.height + side * 0.16 : side * 0.36)
                    + side * 0.05 * phase.fingerLift
            )
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: phase.fingerApproached)
            .animation(.easeInOut(duration: 0.16), value: phase.fingerLift)
    }

    /// 단축어 등록 완료 카드 — 폰 우상단에 살짝 겹쳐서 spring 등장. backtap.png 시안과 같이
    /// 카드 좌측이 폰 카메라 모듈 위에 살짝 올라타며 우측 가장자리는 hero 영역 안에 머무름.
    private func cardLayer(side: CGFloat) -> some View {
        ShortcutRegisteredCard()
            .scaleEffect(phase.cardRevealed ? 1.0 : 0.55)
            .opacity(phase.cardRevealed ? 1.0 : 0)
            .offset(x: side * 0.18, y: -side * 0.38)
            .animation(.spring(response: 0.55, dampingFraction: 0.7), value: phase.cardRevealed)
    }

    /// 폰 주위 sparkle 4개 — 임의 각도/거리/크기/지연으로 "규칙성" 회피.
    /// 6각 균등 배치 → 4개 비대칭 배치 + 각각 다른 size/opacity/delay.
    private func sparkleLayer(side: CGFloat) -> some View {
        let specs: [(angleDeg: Double, radius: CGFloat, size: CGFloat, opacity: Double, delay: Double)] = [
            (angleDeg:  38, radius: 0.42, size: 13, opacity: 0.80, delay: 0.00),
            (angleDeg: 142, radius: 0.30, size:  9, opacity: 0.60, delay: 0.12),
            (angleDeg: 226, radius: 0.36, size: 11, opacity: 0.70, delay: 0.06),
            (angleDeg: 328, radius: 0.26, size:  8, opacity: 0.55, delay: 0.18),
        ]
        return ZStack {
            ForEach(specs.indices, id: \.self) { i in
                let s = specs[i]
                let rad = s.angleDeg * .pi / 180
                let dx = cos(rad) * side * s.radius
                let dy = sin(rad) * side * s.radius * 0.85
                Image(systemName: "sparkle")
                    .font(.system(size: s.size, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.primary)
                    .scaleEffect(phase.cardRevealed ? 1.0 : 0.2)
                    .opacity(phase.cardRevealed ? s.opacity : 0)
                    .offset(x: phase.cardRevealed ? dx : 0, y: phase.cardRevealed ? dy : 0)
                    .animation(
                        .spring(response: 0.7, dampingFraction: 0.65).delay(s.delay),
                        value: phase.cardRevealed
                    )
            }
        }
    }

    // MARK: Loop

    /// idle (700ms) → approach (450ms) → tap1↓↑ (200+220) → tap2↓↑ (200+280)
    /// → reveal (700ms) → hold (1500ms) → reset (700ms). 총 ≈ 4.85s/cycle.
    private func runLoop() async {
        withAnimation(.easeInOut(duration: 0.4)) { phase = .idle }
        try? await Task.sleep(for: .milliseconds(700))

        while !Task.isCancelled {
            withAnimation { phase = .approach }
            try? await Task.sleep(for: .milliseconds(450))

            // Tap 1
            withAnimation(.easeInOut(duration: 0.16)) { phase = .tap1Down }
            pulseTrigger &+= 1
            try? await Task.sleep(for: .milliseconds(200))

            withAnimation(.easeInOut(duration: 0.18)) { phase = .tap1Up }
            try? await Task.sleep(for: .milliseconds(220))

            // Tap 2
            withAnimation(.easeInOut(duration: 0.16)) { phase = .tap2Down }
            pulseTrigger &+= 1
            try? await Task.sleep(for: .milliseconds(200))

            withAnimation(.easeInOut(duration: 0.18)) { phase = .tap2Up }
            try? await Task.sleep(for: .milliseconds(280))

            // Card + sparkle 등장
            withAnimation { phase = .reveal }
            try? await Task.sleep(for: .milliseconds(700))

            // Hold
            withAnimation { phase = .hold }
            try? await Task.sleep(for: .milliseconds(1500))

            // Reset
            withAnimation(.easeInOut(duration: 0.5)) { phase = .idle }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}

// MARK: - PulseRipple

/// 한 번의 탭마다 동심원이 0.3 → 1.8 로 퍼지며 fade out. `trigger` 정수가 바뀔 때마다 재시작.
private struct PulseRipple: View {
    let trigger: Int
    let baseSize: CGFloat

    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(OnboardingTheme.primary.opacity(0.7), lineWidth: 2.5)
                .frame(width: baseSize, height: baseSize)
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .onChange(of: trigger) { _, _ in
            scale = 0.35
            opacity = 0.85
            withAnimation(.easeOut(duration: 0.6)) {
                scale = 1.9
                opacity = 0
            }
        }
    }
}

// MARK: - ShortcutRegisteredCard

/// 단축어 등록 완료를 알리는 카드. iOS 단축어 앱 공식 아이콘 + 체크 + 2줄 텍스트.
private struct ShortcutRegisteredCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("shortcuts_icon")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.green)
                    Text("단축어 등록 완료!")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(OnboardingTheme.titleColor)
                }
                Text("두 번 탭으로\n빠르게 실행해요")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(OnboardingTheme.subtitleColor)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
                .shadow(color: Color.black.opacity(0.09), radius: 16, x: 0, y: 9)
        )
    }
}

#if DEBUG
#Preview {
    BackTapPage()
        .background(OnboardingTheme.backgroundGradient.ignoresSafeArea())
}
#endif
