import SwiftUI

/// 모찌 디자인 시스템의 단일 진입점. Color·Typography·Spacing 토큰만 노출한다.
///
/// 컴포넌트가 직접 `Color.red` 같은 raw 값을 쓰지 않도록 모든 시각 토큰을 여기에서 정의.
/// 자산 카탈로그가 필요해지면 `Targets/Cores/DesignSystem/Resources/Assets.xcassets`를 추가하고
/// Tuist `resources` 슬롯을 켠다.
public enum MochiTheme {
    public enum Palette {
        public static let primary       = Color(red: 0.545, green: 0.424, blue: 1.0) // 모찌 퍼플 (home-mockup 시안 purple500 승격)
        public static let secondary     = Color(red: 0.99, green: 0.92, blue: 0.58) // 골드
        public static let background    = Color(uiColorLight: 0xFFFFFF, dark: 0x111111)
        public static let surface       = Color(uiColorLight: 0xF6F6F6, dark: 0x1C1C1E)
        public static let textPrimary   = Color(uiColorLight: 0x111111, dark: 0xF6F6F6)
        public static let textSecondary = Color(uiColorLight: 0x6C6C70, dark: 0xAEAEB2)
        public static let accent        = Color(red: 0.18, green: 0.24, blue: 0.49) // navy
    }

    public enum Typography {
        public static let title       = Font.system(.title, design: .rounded).weight(.bold)
        public static let headline    = Font.system(.headline, design: .rounded)
        public static let body        = Font.system(.body)
        public static let caption     = Font.system(.caption).monospacedDigit()
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat  = 8
        public static let m: CGFloat  = 16
        public static let l: CGFloat  = 24
        public static let xl: CGFloat = 32
    }

    public enum Radius {
        public static let s: CGFloat  = 8
        public static let m: CGFloat  = 12
        public static let l: CGFloat  = 20
    }
}

private extension Color {
    /// Hex 정수를 light/dark 두 값으로 합성하여 dynamic Color 생성.
    init(uiColorLight light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        let resolver: (UITraitCollection) -> UIColor = { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        self.init(UIColor(dynamicProvider: resolver))
        #else
        self.init(red: 0, green: 0, blue: 0)
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
