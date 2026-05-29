import SwiftUI

/// 홈 시안 전용 디자인 토큰.
///
/// `MochiTheme` 토큰이 _workspace/home-mockup 의 풍부한 팔레트를 아직 커버하지 못해,
/// 시안이 코드로 확정되기 전까지 로컬 토큰으로 분리. DesignSystem 승격은 사용자 OK 후.
enum HomeDesign {
    enum Color {
        static let purple50  = SwiftUI.Color(red: 0.957, green: 0.937, blue: 1.000)
        static let purple100 = SwiftUI.Color(red: 0.929, green: 0.906, blue: 1.000)
        static let purple200 = SwiftUI.Color(red: 0.847, green: 0.796, blue: 1.000)
        static let purple400 = SwiftUI.Color(red: 0.627, green: 0.518, blue: 1.000)
        static let purple500 = SwiftUI.Color(red: 0.545, green: 0.424, blue: 1.000)
        static let purple600 = SwiftUI.Color(red: 0.435, green: 0.314, blue: 0.910)
        static let purpleGlow = SwiftUI.Color(red: 0.706, green: 0.604, blue: 1.000)

        static let cream50  = SwiftUI.Color(red: 1.000, green: 0.992, blue: 0.973)
        static let cream100 = SwiftUI.Color(red: 1.000, green: 0.976, blue: 0.945)
        static let cream200 = SwiftUI.Color(red: 0.969, green: 0.925, blue: 0.867)

        static let mint100  = SwiftUI.Color(red: 0.875, green: 0.973, blue: 0.925)
        static let mint400  = SwiftUI.Color(red: 0.298, green: 0.796, blue: 0.561)

        static let butter50  = SwiftUI.Color(red: 1.000, green: 0.973, blue: 0.871)
        static let butter100 = SwiftUI.Color(red: 1.000, green: 0.937, blue: 0.769)
        static let butter400 = SwiftUI.Color(red: 0.898, green: 0.706, blue: 0.208)

        static let blush100 = SwiftUI.Color(red: 1.000, green: 0.878, blue: 0.894)
        static let blush400 = SwiftUI.Color(red: 0.937, green: 0.494, blue: 0.569)

        static let sky100   = SwiftUI.Color(red: 0.867, green: 0.933, blue: 1.000)
        static let sky400   = SwiftUI.Color(red: 0.420, green: 0.663, blue: 1.000)

        static let peach400 = SwiftUI.Color(red: 1.000, green: 0.608, blue: 0.451)

        static let ink900 = SwiftUI.Color(red: 0.090, green: 0.090, blue: 0.165)
        static let ink700 = SwiftUI.Color(red: 0.216, green: 0.216, blue: 0.314)
        static let ink500 = SwiftUI.Color(red: 0.478, green: 0.478, blue: 0.565)
        static let ink300 = SwiftUI.Color(red: 0.722, green: 0.722, blue: 0.784)
        static let ink100 = SwiftUI.Color(red: 0.925, green: 0.925, blue: 0.957)

        static let surface     = SwiftUI.Color.white
        static let bg          = cream100
        static let textPrimary = ink900
        static let textMuted   = ink500
        static let textFaint   = ink300
        static let border      = ink100
    }

    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let full: CGFloat = 999
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }
}

// MARK: - Modifiers

struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: HomeDesign.Color.ink900.opacity(0.06), radius: 18, x: 0, y: 6)
    }
}

extension View {
    func cardShadow() -> some View { modifier(CardShadow()) }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
