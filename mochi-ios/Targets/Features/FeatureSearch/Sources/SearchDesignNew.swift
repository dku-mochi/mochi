import SwiftUI
import CoreDomain

/// 검색 탭 새 시안 (D5+) — 사용자 디자인 가이드 정합 토큰 셋.
///
/// 기존 `SearchDesign` 은 보존 (이전 view 들 호환). 새 view 는 이 namespace 사용.
/// 점진 마이그레이션 끝나면 통합/정리.
public enum SearchD5 {

    // MARK: - Palette

    public enum Palette {
        // Primary
        static let primary       = Color(red: 0x8B/255.0, green: 0x5C/255.0, blue: 0xF6/255.0) // #8B5CF6
        static let primaryDeep   = Color(red: 0x7C/255.0, green: 0x3A/255.0, blue: 0xED/255.0) // #7C3AED
        static let primaryLight  = Color(red: 0xA7/255.0, green: 0x8B/255.0, blue: 0xFA/255.0) // #A78BFA
        static let primaryPale   = Color(red: 0xF1/255.0, green: 0xEA/255.0, blue: 0xFF/255.0) // #F1EAFF

        // Background
        static let bgCream       = Color(red: 0xFA/255.0, green: 0xF7/255.0, blue: 0xF1/255.0) // #FAF7F1
        static let bgLavender    = Color(red: 0xEE/255.0, green: 0xE6/255.0, blue: 0xFF/255.0) // #EEE6FF
        static let bgPink        = Color(red: 0xFF/255.0, green: 0xF1/255.0, blue: 0xF8/255.0) // #FFF1F8
        static let bgCool        = Color(red: 0xF7/255.0, green: 0xF7/255.0, blue: 0xFB/255.0) // #F7F7FB

        // Card
        static let card          = Color.white
        static let cardBorder    = Color(red: 0xEC/255.0, green: 0xEA/255.0, blue: 0xF3/255.0) // #ECEAF3
        static let cardShadow    = Color(red: 80/255.0, green: 70/255.0, blue: 120/255.0).opacity(0.08)
        static let cardShadowStrong = Color(red: 80/255.0, green: 70/255.0, blue: 120/255.0).opacity(0.16)
        static let divider       = Color(red: 0xE7/255.0, green: 0xE4/255.0, blue: 0xEE/255.0) // #E7E4EE

        // Text
        static let textPrimary   = Color(red: 0x1F/255.0, green: 0x24/255.0, blue: 0x33/255.0) // #1F2433
        static let textSecondary = Color(red: 0x6F/255.0, green: 0x72/255.0, blue: 0x85/255.0) // #6F7285
        static let textTertiary  = Color(red: 0xA3/255.0, green: 0xA6/255.0, blue: 0xB5/255.0) // #A3A6B5
        static let textDisabled  = Color(red: 0xC7/255.0, green: 0xCA/255.0, blue: 0xD6/255.0) // #C7CAD6
        static let placeholder   = Color(red: 0xA8/255.0, green: 0xA6/255.0, blue: 0xB5/255.0) // #A8A6B5

        // Highlight (검색어)
        static let highlightBg   = Color(red: 0xF0/255.0, green: 0xE6/255.0, blue: 0xFF/255.0) // #F0E6FF
        static let highlightFg   = textPrimary

        // CTA / 검색바 포커스 그라데이션
        static let ctaGradient = LinearGradient(
            gradient: Gradient(colors: [primary, primaryDeep]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        // 상단 헤더 워시 — 포커스 화면 부드러운 배경
        static let headerWash = LinearGradient(
            gradient: Gradient(stops: [
                .init(color: bgLavender, location: 0.00),
                .init(color: bgPink,     location: 0.50),
                .init(color: bgCream,    location: 1.00),
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Type Filter (기본 화면 — 출처/타입 5축)

    /// 검색 탭 *기본* 화면의 필터칩.
    /// 명세: 전체 / 링크 / 스크린샷 / 메모 / 미확인 (needsReview).
    public enum TypeFilter: String, CaseIterable, Sendable, Identifiable {
        case all, link, screenshot, memo, unconfirmed

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .all:         return "전체"
            case .link:        return "링크"
            case .screenshot:  return "스크린샷"
            case .memo:        return "메모"
            case .unconfirmed: return "미확인"
            }
        }
        public var systemImage: String {
            switch self {
            case .all:         return "square.grid.2x2"
            case .link:        return "link"
            case .screenshot:  return "photo"
            case .memo:        return "doc.text"
            case .unconfirmed: return "circle"
            }
        }
        public var activeBg: Color {
            switch self {
            case .all:         return Color(red: 0xF1/255.0, green: 0xEA/255.0, blue: 0xFF/255.0)
            case .link:        return Color(red: 0xF3/255.0, green: 0xEE/255.0, blue: 0xFF/255.0)
            case .screenshot:  return Color(red: 0xEA/255.0, green: 0xF3/255.0, blue: 0xFF/255.0)
            case .memo:        return Color(red: 0xFF/255.0, green: 0xF1/255.0, blue: 0xE8/255.0)
            case .unconfirmed: return Color(red: 0xF3/255.0, green: 0xF4/255.0, blue: 0xF8/255.0)
            }
        }
        public var activeFg: Color {
            switch self {
            case .all:         return Color(red: 0x7C/255.0, green: 0x3A/255.0, blue: 0xED/255.0)
            case .link:        return Color(red: 0x8B/255.0, green: 0x5C/255.0, blue: 0xF6/255.0)
            case .screenshot:  return Color(red: 0x4F/255.0, green: 0x8D/255.0, blue: 0xF7/255.0)
            case .memo:        return Color(red: 0xE4/255.0, green: 0x7B/255.0, blue: 0x36/255.0)
            case .unconfirmed: return Color(red: 0x6F/255.0, green: 0x72/255.0, blue: 0x85/255.0)
            }
        }

        /// 모찌 1건이 이 필터에 매칭되는가.
        public func matches(_ item: MochiItem) -> Bool {
            switch self {
            case .all:         return true
            case .link:        return item.source.url != nil
            case .screenshot:  return !item.source.imageRefs.isEmpty
                                || item.source.channel == .screenshot
            case .memo:        return item.source.url == nil
                                && item.source.imageRefs.isEmpty
                                && item.source.channel != .screenshot
            case .unconfirmed: return item.needsReview
            }
        }
    }

    // MARK: - Intent (결과 화면 — 일정/할일/지식/기록)

    public enum IntentColor {
        public static func bg(_ intent: Intent) -> Color {
            switch intent {
            case .schedule:  return Color(red: 0xEA/255.0, green: 0xF3/255.0, blue: 0xFF/255.0) // #EAF3FF
            case .todo:      return Color(red: 0xFF/255.0, green: 0xF1/255.0, blue: 0xE3/255.0) // #FFF1E3
            case .knowledge: return Color(red: 0xE8/255.0, green: 0xF8/255.0, blue: 0xF0/255.0) // #E8F8F0
            case .memo:      return Color(red: 0xFF/255.0, green: 0xEA/255.0, blue: 0xF0/255.0) // #FFEAF0
            }
        }
        public static func fg(_ intent: Intent) -> Color {
            switch intent {
            case .schedule:  return Color(red: 0x4F/255.0, green: 0x8D/255.0, blue: 0xF7/255.0) // #4F8DF7
            case .todo:      return Color(red: 0xE4/255.0, green: 0x7B/255.0, blue: 0x36/255.0) // #E47B36
            case .knowledge: return Color(red: 0x31/255.0, green: 0xA8/255.0, blue: 0x79/255.0) // #31A879
            case .memo:      return Color(red: 0xED/255.0, green: 0x6F/255.0, blue: 0x8C/255.0) // #ED6F8C
            }
        }
        public static func label(_ intent: Intent) -> String {
            switch intent {
            case .schedule:  return "일정"
            case .todo:      return "할일"
            case .knowledge: return "지식"
            case .memo:      return "기록"
            }
        }
        public static func systemImage(_ intent: Intent) -> String {
            switch intent {
            case .schedule:  return "calendar"
            case .todo:      return "checkmark.square"
            case .knowledge: return "book.closed"
            case .memo:      return "doc.text"
            }
        }
    }

    // MARK: - Sizes

    public enum Sizes {
        static let pageH: CGFloat            = 14
        static let searchBarHeight: CGFloat  = 48
        static let searchBarRadius: CGFloat  = 24
        static let filterChipHeight: CGFloat = 32
        static let filterChipRadius: CGFloat = 16
        static let gridGap: CGFloat          = 10
        static let gridCardRadius: CGFloat   = 22
        static let gridCardHeight: CGFloat   = 138
        static let cardPadding: CGFloat      = 10
        static let badgeHeight: CGFloat      = 22
        static let badgeRadius: CGFloat      = 11
        static let ctaButtonHeight: CGFloat  = 56
        static let ctaButtonRadius: CGFloat  = 20
        static let emptyMascotSize: CGFloat  = 220
        static let helloMascotSize: CGFloat  = 180
        static let sectionGap: CGFloat       = 28
        static let componentGap: CGFloat     = 12
    }
}
