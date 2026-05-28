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
