import SwiftUI
import DesignSystem

/// 앱 부팅 직후 노출되는 스플래시 화면.
/// `UILaunchScreen` 은 빈 dict 라서 시스템은 흰 화면만 잠깐 보여주고,
/// 실제 브랜딩은 이 SwiftUI 뷰에서 책임진다.
///
/// 모찌가 톡 등장하는 순간, **모찌 뒤(가려진 중앙)에서 생일폭죽이 터져** 색종이가
/// 솟구쳐 흩날린다(`ConfettiCannonLayer`). confetti 레이어가 ZStack 에서 모찌(content)
/// 아래에 있어 초기엔 모찌에 가려졌다가 밖으로 솟아나오는 연출이 자연스럽게 나온다.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var particles: [ConfettiParticle] = []
    @State private var launchDate: Date?

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            if let launchDate {
                ConfettiCannonLayer(particles: particles, launchDate: launchDate)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            content
        }
        .onAppear { start() }
    }

    private func start() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.68)) {
            hasAppeared = true
        }
        // 색종이는 모션 민감 사용자에겐 생략 — 모찌만 차분히 등장.
        guard !reduceMotion, launchDate == nil else { return }
        particles = ConfettiParticle.partyPopperBurst()
        launchDate = Date()
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.84, green: 0.83, blue: 0.96), location: 0.0),
                .init(color: Color(red: 0.89, green: 0.87, blue: 0.96), location: 0.45),
                .init(color: Color(red: 0.93, green: 0.88, blue: 0.94), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Content

    private var content: some View {
        GeometryReader { proxy in
            Image("SplashMochi")
                .resizable()
                .scaledToFit()
                .frame(width: min(proxy.size.width * 0.62, 280))
                .shadow(color: HomeDesign.Color.purple500.opacity(0.18), radius: 22, x: 0, y: 14)
//                .scaleEffect(hasAppeared ? 1.0 : 0.6)
//                .opacity(hasAppeared ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - 생일폭죽(파티 포퍼) 색종이 레이어

/// 모찌 뒤에서 색종이가 솟구쳐 흩날리며 떨어지는 1회성 연출.
/// 입자 위치는 발사 시각 기준 경과 `t` 의 **결정론적 함수**라 상태 누적 없이
/// `TimelineView(.animation)` 의 매 프레임마다 `Canvas` 로 한 번에 GPU 렌더한다
/// (수백 개를 개별 `View` 로 만들 때의 diff·레이아웃 비용 제거).
private struct ConfettiCannonLayer: View {
    let particles: [ConfettiParticle]
    let launchDate: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(launchDate)
                guard elapsed >= 0 else { return }
                for particle in particles {
                    particle.draw(in: &context, elapsed: elapsed, canvas: size)
                }
            }
        }
    }
}

/// 색종이 한 조각.
///
/// **선형 drag 모델** — 포물선(중력만)은 상승·하강이 대칭이라 화면 체공이 짧다.
/// 실제 색종이가 화려한 건 가벼워서 공기저항으로 천천히 팔랑팔랑 떨어지기 때문이라,
/// 속도에 비례하는 저항을 줘 "솟구침 → 급감속 → 종단속도 등속 낙하"로 모델링한다.
/// 속도·중력은 기준 높이(844pt)값이며 `draw` 에서 실제 화면 높이에 비례 스케일한다.
private struct ConfettiParticle {
    enum Kind { case confetti, ribbon, dot }

    let origin: CGPoint        // 정규화 좌표(0~1) — 모찌 뒤 중앙 근처
    let vx0: CGFloat           // 초기 속도 (pt/s, 844 기준)
    let vy0: CGFloat           // 초기 속도 — 음수 = 위로
    let drag: CGFloat          // 속도 감쇠 계수 k (1/s)
    let gravity: CGFloat       // 중력 (pt/s², 844 기준). 종단속도 = gravity/drag
    let color: Color
    let length: CGFloat
    let kind: Kind
    let spin: Double           // 2D 회전 속도 (deg/s)
    let spinPhase: Double
    let flipRate: Double       // 3D flip 속도 (rad/s)
    let flipPhase: Double
    let swayAmp: CGFloat       // 낙하 중 좌우 흔들림 진폭
    let swayRate: Double
    let swayPhase: Double
    let launchDelay: TimeInterval
    let lifetime: TimeInterval

    func draw(in context: inout GraphicsContext, elapsed: TimeInterval, canvas: CGSize) {
        let t = elapsed - launchDelay
        guard t >= 0, t < lifetime else { return }

        let scale = canvas.height / 844
        let k = drag
        let decay = CGFloat(exp(-Double(k) * t))      // e^{-kt}
        let termVy = gravity * scale / k              // 종단속도(아래방향)
        let originX = origin.x * canvas.width
        let originY = origin.y * canvas.height
        let sway = swayAmp * CGFloat(sin(swayRate * t + swayPhase))
        let x = originX + (vx0 * scale / k) * (1 - decay) + sway
        let y = originY + termVy * CGFloat(t) + ((vy0 * scale - termVy) / k) * (1 - decay)
        guard y < canvas.height + 60 else { return }  // 화면 아래로 떨어진 조각은 건너뜀

        let fadeWindow: TimeInterval = 0.5
        let fadeStart = lifetime - fadeWindow
        let opacity = t < fadeStart ? 1.0 : max(0, 1 - (t - fadeStart) / fadeWindow)
        // |cos| 으로 앞뒤가 뒤집히며 얇아졌다 두꺼워지는 3D flip 을 가로 스케일로 흉내.
        let flip = max(0.16, abs(cos(flipRate * t + flipPhase)))

        context.drawLayer { layer in
            layer.opacity = opacity
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .degrees(spinPhase + spin * t))
            layer.scaleBy(x: CGFloat(flip), y: 1)
            layer.fill(shapePath, with: .color(color))
        }
    }

    private var shapePath: Path {
        switch kind {
        case .confetti:
            let w = length, h = length * 0.62
            return Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: length * 0.16)
        case .ribbon:
            let w = length * 0.34, h = length * 1.5
            return Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: w * 0.5)
        case .dot:
            return Path(ellipseIn: CGRect(x: -length / 2, y: -length / 2, width: length, height: length))
        }
    }

    /// 모찌 뒤(화면 중앙)에서 거의 전방위로 솟구치는 한 발의 생일폭죽.
    static func partyPopperBurst() -> [ConfettiParticle] {
        let palette: [Color] = [
            HomeDesign.Color.blush400,
            HomeDesign.Color.peach400,
            HomeDesign.Color.mint400,
            HomeDesign.Color.sky400,
            HomeDesign.Color.purple400,
        ]
        var particles: [ConfettiParticle] = []

        for _ in 0..<30 {
            let speed = CGFloat.random(in: 200...390)
            let angle = CGFloat.random(in: -2.62...2.62)   // 수직 위 기준 ±150°(위 중심, 옆구리 아래까지)
            let kindRoll = Double.random(in: 0...1)
            let kind: Kind = kindRoll < 0.60 ? .confetti : (kindRoll < 0.85 ? .ribbon : .dot)
            particles.append(
                ConfettiParticle(
                    origin: CGPoint(x: 0.5 + .random(in: -0.025...0.025), y: 0.45 + .random(in: -0.02...0.02)),
                    vx0: speed * sin(angle),
                    vy0: -speed * cos(angle) * 3,
                    drag: CGFloat.random(in: 1.5...2.05),
                    gravity: CGFloat.random(in: 200...580),
                    color: palette.randomElement()!,
                    length: kind == .dot ? .random(in: 6...10) : .random(in: 9...17),
                    kind: kind,
                    spin: .random(in: -340...340),
                    spinPhase: .random(in: 0...360),
                    flipRate: .random(in: 5...12),
                    flipPhase: .random(in: 0...(2 * .pi)),
                    swayAmp: .random(in: 9...26),
                    swayRate: .random(in: 2.4...5.0),
                    swayPhase: .random(in: 0...(2 * .pi)),
                    launchDelay: .random(in: 0...0.42),
                    lifetime: .random(in: 3.0...4.5)
                )
            )
        }
        return particles
    }
}

#Preview {
    SplashView()
}
