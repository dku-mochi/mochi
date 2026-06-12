import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 탭 토큰 셋 — `HomeDesign` 위에 검색 전용(TypeFilter/IntentColor) 만 얹은 얇은 레이어.
///
/// D5 단계에선 별도 namespace 였지만 D6 에서 톤 일치를 위해 `HomeDesign` 을 단일 원천으로 삼고,
/// 검색 고유의 *5축 출처/타입 필터* 색·*결과 화면 Intent 색* 만 여기서 정의.
public enum SearchD5 {

    // MARK: - Palette (HomeDesign 위임)

    public enum Palette {
        // Primary — HomeDesign purple500/600/100/50 으로 통일.
        public static let primary       = HomeDesign.Color.purple500
        public static let primaryDeep   = HomeDesign.Color.purple600
        public static let primaryLight  = HomeDesign.Color.purple400
        public static let primaryPale   = HomeDesign.Color.purple50

        // Background — 홈/캘린더와 동일 cool gray.
        public static let bgCream       = HomeDesign.Color.bg

        // Card
        public static let card          = HomeDesign.Color.surface
        public static let cardBorder    = HomeDesign.Color.border
        // shadow color — cardShadow() modifier 와 동일 톤.
        public static let cardShadow    = HomeDesign.Color.ink900.opacity(0.06)
        public static let divider       = HomeDesign.Color.ink100

        // Text
        public static let textPrimary   = HomeDesign.Color.textPrimary
        public static let textSecondary = HomeDesign.Color.textMuted
        public static let textTertiary  = HomeDesign.Color.textFaint
        public static let placeholder   = HomeDesign.Color.textFaint

        // Highlight (검색어 강조)
        public static let highlightBg   = HomeDesign.Color.butter100
        public static let highlightFg   = HomeDesign.Color.ink900

        // CTA gradient
        public static let ctaGradient = LinearGradient(
            gradient: Gradient(colors: [HomeDesign.Color.purple500, HomeDesign.Color.purple600]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        // focused 화면 상단 wash — bg 위에 아주 낮은 opacity 보조 레이어로만.
        public static let headerWash = LinearGradient(
            gradient: Gradient(stops: [
                .init(color: HomeDesign.Color.purple50.opacity(0.6), location: 0.00),
                .init(color: HomeDesign.Color.bg.opacity(0.0),       location: 1.00),
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Type Filter (기본 화면 — 출처/타입 5축)

    /// 검색 탭 *기본* 화면의 필터칩.
    /// 명세: 전체 / 링크 / 스크린샷 / 메모 / 미확인 (needsReview).
    /// 색은 HomeDesign 의 파스텔 톤으로 약화 — fg 만 또렷, bg 는 부드러운 보조 fill.
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
            case .all:         return HomeDesign.Color.purple50
            case .link:        return HomeDesign.Color.purple50
            case .screenshot:  return HomeDesign.Color.sky100
            case .memo:        return HomeDesign.Color.butter50
            case .unconfirmed: return HomeDesign.Color.ink100
            }
        }
        public var activeFg: Color {
            switch self {
            case .all:         return HomeDesign.Color.purple600
            case .link:        return HomeDesign.Color.purple500
            case .screenshot:  return HomeDesign.Color.sky400
            case .memo:        return HomeDesign.Color.peach400
            case .unconfirmed: return HomeDesign.Color.ink500
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
            case .schedule:  return HomeDesign.Color.sky100
            case .todo:      return HomeDesign.Color.butter50
            case .knowledge: return HomeDesign.Color.mint100
            case .memo:      return HomeDesign.Color.blush100
            }
        }
        public static func fg(_ intent: Intent) -> Color {
            switch intent {
            case .schedule:  return HomeDesign.Color.sky400
            case .todo:      return HomeDesign.Color.peach400
            case .knowledge: return HomeDesign.Color.mint400
            case .memo:      return HomeDesign.Color.blush400
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
        // 홈 item 카드(RecentMochiCard)와 같은 HomeDesign.Radius.md — 둥글둥글한 인상 제거.
        static let gridCardRadius: CGFloat   = HomeDesign.Radius.md
        static let gridCardHeight: CGFloat   = 138
        static let cardPadding: CGFloat      = 10
        static let ctaButtonHeight: CGFloat  = 56
        static let ctaButtonRadius: CGFloat  = HomeDesign.Radius.md
        static let emptyMascotSize: CGFloat  = 220
        static let helloMascotSize: CGFloat  = 180
        static let sectionGap: CGFloat       = 28
        static let componentGap: CGFloat     = 12
    }
}
