import SwiftUI

/// 모찌 공용 디자인 토큰 (home-mockup 시안 팔레트).
///
/// `MochiTheme` 가 시안의 풍부한 파스텔 팔레트를 아직 커버하지 못해 분리된 토큰 셋.
/// FeatureInbox 에서 출발해 DesignSystem 으로 승격(FeatureDetail 등 다른 Feature 가 재사용).
public enum HomeDesign {
    public enum Color {
        public static let purple50  = SwiftUI.Color(red: 0.957, green: 0.937, blue: 1.000)
        public static let purple100 = SwiftUI.Color(red: 0.929, green: 0.906, blue: 1.000)
        public static let purple200 = SwiftUI.Color(red: 0.847, green: 0.796, blue: 1.000)
        public static let purple400 = SwiftUI.Color(red: 0.627, green: 0.518, blue: 1.000)
        public static let purple500 = SwiftUI.Color(red: 0.545, green: 0.424, blue: 1.000)
        public static let purple600 = SwiftUI.Color(red: 0.435, green: 0.314, blue: 0.910)
        public static let purpleGlow = SwiftUI.Color(red: 0.706, green: 0.604, blue: 1.000)

        public static let cream50  = SwiftUI.Color(red: 1.000, green: 0.992, blue: 0.973)
        public static let cream100 = SwiftUI.Color(red: 1.000, green: 0.976, blue: 0.945)
        public static let cream200 = SwiftUI.Color(red: 0.969, green: 0.925, blue: 0.867)

        public static let mint100  = SwiftUI.Color(red: 0.875, green: 0.973, blue: 0.925)
        public static let mint400  = SwiftUI.Color(red: 0.298, green: 0.796, blue: 0.561)

        public static let butter50  = SwiftUI.Color(red: 1.000, green: 0.973, blue: 0.871)
        public static let butter100 = SwiftUI.Color(red: 1.000, green: 0.937, blue: 0.769)
        public static let butter400 = SwiftUI.Color(red: 0.898, green: 0.706, blue: 0.208)

        public static let blush100 = SwiftUI.Color(red: 1.000, green: 0.878, blue: 0.894)
        public static let blush400 = SwiftUI.Color(red: 0.937, green: 0.494, blue: 0.569)

        public static let sky100   = SwiftUI.Color(red: 0.867, green: 0.933, blue: 1.000)
        public static let sky400   = SwiftUI.Color(red: 0.420, green: 0.663, blue: 1.000)

        public static let peach400 = SwiftUI.Color(red: 1.000, green: 0.608, blue: 0.451)

        public static let ink900 = SwiftUI.Color(red: 0.090, green: 0.090, blue: 0.165)
        public static let ink700 = SwiftUI.Color(red: 0.216, green: 0.216, blue: 0.314)
        public static let ink500 = SwiftUI.Color(red: 0.478, green: 0.478, blue: 0.565)
        public static let ink300 = SwiftUI.Color(red: 0.722, green: 0.722, blue: 0.784)
        public static let ink100 = SwiftUI.Color(red: 0.925, green: 0.925, blue: 0.957)

        public static let surface     = SwiftUI.Color.white
        public static let bg          = SwiftUI.Color(red: 0.949, green: 0.957, blue: 0.969) // F2F4F7 메인 배경
        public static let textPrimary = ink900
        public static let textMuted   = ink500
        public static let textFaint   = ink300
        public static let border      = ink100
    }

    public enum Radius {
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 20
        public static let xl: CGFloat = 24
        public static let full: CGFloat = 999
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
    }
}

// MARK: - Modifiers

struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: HomeDesign.Color.ink900.opacity(0.06), radius: 18, x: 0, y: 6)
    }
}

public extension View {
    func cardShadow() -> some View { modifier(CardShadow()) }
}

/// 섹션이 아래에서 떠오르며 순차 등장하는 entrance 연출 (홈·주간 정리 공용).
/// index 순으로 살짝 시차를 둔다 — 트리거는 화면별 @State 한 번만.
public struct RiseInEffect: ViewModifier {
    let isVisible: Bool
    let index: Int

    public func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 16)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.86).delay(Double(index) * 0.06),
                value: isVisible
            )
    }
}

public extension View {
    func riseIn(_ isVisible: Bool, index: Int) -> some View {
        modifier(RiseInEffect(isVisible: isVisible, index: index))
    }
}

public struct PressableStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
