import SwiftUI

/// 앱 부팅 직후 노출되는 스플래시 화면.
/// `UILaunchScreen` 은 빈 dict 라서 시스템은 흰 화면만 잠깐 보여주고,
/// 실제 브랜딩은 이 SwiftUI 뷰에서 책임진다.
///
/// 온보딩과 같은 연보라 무대 위에서 모찌가 통통 걸어온다. 별도 조명 연출 없이
/// 심플하게 — walk 은 25프레임 시퀀스(24fps)를 토글해 재생한다. 프레임 자체에
/// 발걸음·바운스·squash 가 모두 담겨 있어 코드 변형 없이 그대로 흘려보낸다.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0
    @State private var timer: Timer?

    private let frameCount = 25
    private let fps = 24.0

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            walkingMochi
        }
        .onAppear(perform: start)
        .onDisappear { timer?.invalidate() }
    }

    // MARK: - 배경

    /// 온보딩·로그인 화면과 동일한 연보라 톤. 흐름 연속성을 위해 의도적으로 일치.
    private var backgroundGradient: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.84, green: 0.83, blue: 0.96), location: 0.0),
                .init(color: Color(red: 0.89, green: 0.87, blue: 0.96), location: 0.5),
                .init(color: Color(red: 0.93, green: 0.88, blue: 0.94), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 걷는 모찌

    private var walkingMochi: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width * 0.40, 100)
            ZStack {
                // 발치 접지 그림자 — 은은한 고정 타원.
                Ellipse()
                    .fill(Color(red: 0.42, green: 0.40, blue: 0.52).opacity(0.18))
                    .frame(width: size * 0.50, height: size * 0.085)
                    .blur(radius: 9)
                    .offset(y: size * 0.44)

                Image("MochiWalk\(String(format: "%02d", frame))")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func start() {
        // 모션 민감 사용자: 애니메이션 없이 정지 프레임 한 장만 노출.
        guard !reduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { _ in
            frame = (frame + 1) % frameCount
        }
    }
}

#Preview {
    SplashView()
}
