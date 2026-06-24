import SwiftUI

/// 온보딩 전용 컬러·여백 토큰. `DesignSystem.MochiTheme` 가 아직 코랄 톤이라
/// 시안의 라벤더 톤과 어긋난다. 시안 그대로의 톤을 위해 모듈 로컬 토큰을 둔다.
///
/// 추후 디자인시스템에 "온보딩·로그인 톤" 이 정식 토큰으로 들어오면 그쪽으로 이전.
enum OnboardingTheme {
    /// LoginView 와 동일 그라데이션 — 흐름 연속성을 위해 의도적으로 일치시킨다.
    static let backgroundGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.84, green: 0.83, blue: 0.96), location: 0.0),
            .init(color: Color(red: 0.89, green: 0.87, blue: 0.96), location: 0.45),
            .init(color: Color(red: 0.93, green: 0.88, blue: 0.94), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let titleColor       = Color(red: 0.21, green: 0.20, blue: 0.45)
    static let subtitleColor    = Color(red: 0.36, green: 0.34, blue: 0.55)
    static let mutedTextColor   = Color(red: 0.55, green: 0.55, blue: 0.70)
    static let primary          = Color(red: 0.55, green: 0.46, blue: 0.93)
    static let primaryShadow    = Color(red: 0.55, green: 0.46, blue: 0.93).opacity(0.30)
    static let indicatorOn      = Color(red: 0.55, green: 0.46, blue: 0.93)
    static let indicatorOff     = Color(red: 0.55, green: 0.46, blue: 0.93).opacity(0.25)
}

extension View {
    /// 온보딩 페이지 진입 시 요소별 stagger fade-up — 한 요소씩 또렷이 차례로 떠올라
    /// 사용자 시선을 제목 → 부제 → 히어로 순으로 이끈다. `index` 가 클수록 늦게 등장.
    /// Reduce Motion 이면 세로 이동 없이 페이드만.
    func onboardingEnter(_ index: Int, _ appeared: Bool, reduceMotion: Bool) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (appeared ? 0 : 14))
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)   // 모션 최소화: stagger 없이 빠른 페이드
                    : .smooth(duration: 0.5).delay(0.2 + Double(index) * 0.2),
                value: appeared
            )
    }
}
