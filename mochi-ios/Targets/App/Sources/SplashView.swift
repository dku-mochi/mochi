import SwiftUI

/// 앱 부팅 직후 노출되는 스플래시 화면.
/// `UILaunchScreen` 은 빈 dict 라서 시스템은 흰 화면만 잠깐 보여주고,
/// 실제 브랜딩은 이 SwiftUI 뷰에서 책임진다.
///
/// 온보딩과 같은 연보라 무대 위, 위에서 따뜻한 노란 가로등 빛이 거의 일자로
/// 내려와 모찌를 비춘다. 빛 기둥 + 발치의 빛 웅덩이로 "가로등 밑에 선" 분위기.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var isFloating = false

    /// 가로등 빛 색 — 따뜻한 앰버-옐로우(나트륨등 톤).
    private let lampLight = Color(red: 1.0, green: 0.80, blue: 0.42)

    var body: some View {
        ZStack {
            stageLighting
                .ignoresSafeArea()

            content
        }
        .onAppear { start() }
    }

    private func start() {
        // 모션 민감 사용자: 부유 없이 모찌만 정적으로 즉시 표시.
        guard !reduceMotion else {
            hasAppeared = true
            return
        }
        // 빛 속으로 부드럽게 떠오르며 등장.
        withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) {
            hasAppeared = true
        }
        // 등장 후 은은한 상하 부유를 무한 반복.
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            isFloating = true
        }
    }

    // MARK: - 무대 조명(위에서 내려오는 가로등 빛)

    /// 온보딩 연보라 배경 + 위에서 내려오는 노란 빛 기둥 + 모찌 발치 빛 웅덩이 +
    /// cone 바깥의 약한 그늘. 밝은 배경이라 빛은 normal 합성으로 '색'을 살리고,
    /// 바깥을 살짝 눌러 빛 기둥이 도드라지게 한다.
    private var stageLighting: some View {
        GeometryReader { proxy in
            let major = max(proxy.size.width, proxy.size.height)
            ZStack {
                backgroundGradient

                // ① 빛 기둥 — 위에서 내려오는 따뜻한 노란 cone(살짝만 벌어져 일자에 가깝게).
                LightBeamShape()
                    .fill(
                        LinearGradient(
                            colors: [lampLight.opacity(0.55), lampLight.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blur(radius: 30)

                // ② 바닥 빛 웅덩이 — 빛이 닿는 모찌 발치를 따뜻하게 밝힌다.
                RadialGradient(
                    gradient: Gradient(colors: [lampLight.opacity(0.42), lampLight.opacity(0.0)]),
                    center: UnitPoint(x: 0.5, y: 0.56),
                    startRadius: 0,
                    endRadius: major * 0.36
                )

                // ③ cone 바깥을 약하게 눌러 빛 기둥을 도드라지게(가로등 밤 느낌, 약하게).
                RadialGradient(
                    gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.12)]),
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: major * 0.24,
                    endRadius: major * 0.64
                )
            }
        }
    }

    private var backgroundGradient: some View {
        // 온보딩·로그인 화면과 동일한 연보라 톤(OnboardingTheme.backgroundGradient 미러).
        // 흐름 연속성을 위해 의도적으로 일치. DesignSystem 정식 토큰화 시 공유 예정.
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
            let size = min(proxy.size.width * 0.62, 280)
            ZStack {
                // 바닥 그림자 — 가로등 빛이 위에서 오니 발밑에 깔리는 접지 그림자.
                // 모찌가 떠오르면 그림자도 작아지고 옅어져 부유감을 강화한다.
                Ellipse()
                    .fill(Color(red: 0.30, green: 0.24, blue: 0.42).opacity(0.30))
                    .frame(width: size * 0.70, height: size * 0.12)
                    .blur(radius: 14)
                    .scaleEffect(isFloating ? 0.92 : 1.0)
                    .opacity(isFloating ? 0.8 : 1.0)
                    .offset(y: size * 0.46)
                    .opacity(hasAppeared ? 1 : 0)

                Image("SplashMochi")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size)
                    // 셀프 셰이딩 — 가로등 빛을 받은 윗면은 노랗게, 가장자리·아래는 그늘.
                    .overlay {
                        // 구체 그늘 — 흰 모찌는 더 밝아질 수 없으니 그늘로 입체를 만든다.
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.clear, location: 0.0),
                                .init(color: Color(red: 0.28, green: 0.22, blue: 0.42).opacity(0.10), location: 0.5),
                                .init(color: Color(red: 0.28, green: 0.22, blue: 0.42).opacity(0.32), location: 1.0),
                            ]),
                            center: UnitPoint(x: 0.5, y: 0.30),
                            startRadius: 0,
                            endRadius: size * 0.55
                        )
                        .blendMode(.multiply)
                    }
                    .overlay {
                        // 정수리에 닿는 따뜻한 가로등 빛.
                        LinearGradient(
                            stops: [
                                .init(color: lampLight.opacity(0.40), location: 0.0),
                                .init(color: Color.clear, location: 0.5),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .compositingGroup()
                    .mask {
                        Image("SplashMochi")
                            .resizable()
                            .scaledToFit()
                            .frame(width: size)
                    }
                    // 부드럽게 아래로 떨어지는 본체 그림자 + 짧은 접지 그림자 2겹.
                    .shadow(color: Color(red: 0.20, green: 0.16, blue: 0.34).opacity(0.22), radius: 20, x: 0, y: 22)
                    .shadow(color: Color.black.opacity(0.12), radius: 7, x: 0, y: 7)
                    .scaleEffect(hasAppeared ? 1.0 : 0.88)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: isFloating ? -size * 0.025 : size * 0.025)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - 위에서 내려오는 가로등 빛 기둥

/// 화면 위 좁은 입구에서 아래로 '살짝만' 벌어지는 사다리꼴 — 가로등 빛 기둥 윤곽.
/// 채움 그라데이션 + blur 로 가장자리를 흐려 공기 중 산란광처럼 보이게 한다.
private struct LightBeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerX = rect.midX
        let topWidth = rect.width * 0.30
        let bottomWidth = rect.width * 0.58
        let topY = -rect.height * 0.05          // 화면 위 밖에서 시작해 입구를 가린다
        let bottomY = rect.height * 0.70
        path.move(to: CGPoint(x: centerX - topWidth / 2, y: topY))
        path.addLine(to: CGPoint(x: centerX + topWidth / 2, y: topY))
        path.addLine(to: CGPoint(x: centerX + bottomWidth / 2, y: bottomY))
        path.addLine(to: CGPoint(x: centerX - bottomWidth / 2, y: bottomY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    SplashView()
}
