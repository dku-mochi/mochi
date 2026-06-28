import Foundation
import SwiftUI
import CoreDomain

// MARK: - UI Intent (view-side)
//
// 도메인의 4-Intent (schedule / todo / knowledge / memo) 를 시안의 색에 매핑.
// 라벨은 도메인 `Intent.displayName`(일정/할일/지식/기록)과 일치시킨다 — 이전의 todo→"알림" 리라벨은 폐기.

public enum MochiViewIntent: String, CaseIterable, Identifiable {
    case record   // = memo
    case alert    // = todo
    case schedule // = schedule
    case knowledge // = knowledge

    public var id: String { rawValue }

    public init(_ intent: Intent) {
        switch intent {
        case .memo:      self = .record
        case .todo:      self = .alert
        case .schedule:  self = .schedule
        case .knowledge: self = .knowledge
        }
    }

    public var domain: Intent {
        switch self {
        case .record:    return .memo
        case .alert:     return .todo
        case .schedule:  return .schedule
        case .knowledge: return .knowledge
        }
    }

    public var label: String { domain.displayName }

    public var dotColor: Color {
        switch self {
        case .record:    return HomeDesign.Color.blush400
        case .alert:     return HomeDesign.Color.butter400
        case .schedule:  return HomeDesign.Color.sky400
        case .knowledge: return HomeDesign.Color.mint400
        }
    }

    public var chipBackground: Color {
        switch self {
        case .record:    return HomeDesign.Color.blush100
        case .alert:     return HomeDesign.Color.butter100
        case .schedule:  return HomeDesign.Color.sky100
        case .knowledge: return HomeDesign.Color.mint100
        }
    }
}

// MARK: - MochiItem kind (view-side)

public enum MochiItemKind {
    case screenshot
    case memo
    case url

    public init(_ source: IngestSource) {
        if !source.imageRefs.isEmpty {
            self = .screenshot
        } else if source.url != nil {
            self = .url
        } else {
            self = .memo
        }
    }

    public var label: String {
        switch self {
        case .screenshot: return "스크린샷"
        case .memo:       return "메모"
        case .url:        return "URL"
        }
    }

    public var icon: String {
        switch self {
        case .screenshot: return "camera"
        case .memo:       return "doc.text"
        case .url:        return "link"
        }
    }

    public var tint: Color {
        switch self {
        case .screenshot: return HomeDesign.Color.ink700
        case .memo:       return HomeDesign.Color.butter400
        case .url:        return HomeDesign.Color.purple600
        }
    }

    public var background: Color {
        switch self {
        case .screenshot: return HomeDesign.Color.cream100
        case .memo:       return HomeDesign.Color.butter50
        case .url:        return HomeDesign.Color.purple50
        }
    }
}

// MARK: - Category palette (카테고리 인덱스 → 파스텔 색쌍)

/// 카테고리별 색을 한 곳에서 정한다 — 홈 "이런 걸 모아두셨어요" 그리드와 카테고리 턴테이블이
/// 같은 인덱스엔 같은 색을 쓰도록 통일한다(같은 서랍이 두 화면에서 다른 색으로 보이지 않게).
/// 시안 home-carousel-prototype 의 6색 팔레트(blush/purple/mint/butter/sky/peach)를 토큰으로 옮긴 것.
public extension Date {
    /// 모찌 공용 상대 시각 라벨(방금 / N분 전 / N시간 전 / N일 전 / N주 전 / M월 d일).
    var mochiRelativeLabel: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return "방금" }
        if interval < 3600 { return "\(Int(interval / 60))분 전" }
        if interval < 86_400 { return "\(Int(interval / 3600))시간 전" }
        let days = Int(interval / 86_400)
        if days <= 7 { return "\(days)일 전" }
        if days <= 30 { return "\(days / 7)주 전" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일"
        return formatter.string(from: self)
    }
}

public enum MochiCategoryPalette {
    /// (옅은 배경 틴트, 강조색) 색쌍. 인덱스를 순환해서 쓴다.
    public static let tints: [(soft: Color, strong: Color)] = [
        (HomeDesign.Color.blush100, HomeDesign.Color.blush400),
        (HomeDesign.Color.purple100, HomeDesign.Color.purple500),
        (HomeDesign.Color.mint100, HomeDesign.Color.mint400),
        (HomeDesign.Color.butter100, HomeDesign.Color.butter400),
        (HomeDesign.Color.sky100, HomeDesign.Color.sky400),
        (HomeDesign.Color.cream100, HomeDesign.Color.peach400),
    ]

    public static func tint(_ index: Int) -> (soft: Color, strong: Color) {
        let count = tints.count
        return tints[((index % count) + count) % count]
    }
}

// MARK: - Category icon (자유형 카테고리 이름 → SF Symbol)

/// LLM 이 만드는 자유형 카테고리 이름을 키워드로 아이콘에 매핑한다 (홈 주간 카드·주간 정리 공용).
/// 매칭 실패 시 순번별 중립 아이콘 — 이름과 무관한 아이콘(예: "투자 관리"에 압정)을 막는다.
public enum MochiCategoryIcon {
    public static func icon(for name: String, fallbackIndex: Int) -> String {
        let n = name.lowercased()
        let keywordIcons: [([String], String)] = [
            (["투자", "주식", "금융", "재테크", "코인"], "chart.line.uptrend.xyaxis"),
            (["일정", "약속", "캘린더"], "calendar"),
            (["할 일", "할일", "업무"], "checklist"),
            (["학습", "공부", "교육", "강의"], "graduationcap.fill"),
            (["it", "테크", "트렌드", "개발", "ai"], "cpu"),
            (["앱", "사용"], "iphone"),
            (["여행", "장소", "맛집", "카페", "데이트"], "mappin.and.ellipse"),
            (["쇼핑", "구매", "위시"], "bag.fill"),
            (["운동", "건강", "헬스"], "heart.fill"),
            (["요리", "음식", "레시피"], "fork.knife"),
            (["음악"], "music.note"),
            (["영상", "영화", "유튜브"], "play.rectangle.fill"),
        ]
        for (keywords, icon) in keywordIcons where keywords.contains(where: { n.contains($0) }) {
            return icon
        }
        return ["bookmark.fill", "tag.fill", "square.grid.2x2.fill"][fallbackIndex % 3]
    }
}

// MARK: - MochiItem → display helpers

extension MochiItem {
    public var displayTitle: String {
        if let headline = displayHeadline, !headline.isEmpty { return headline }
        if let summary = analysis?.summary, !summary.isEmpty { return summary }
        if let text = source.text, !text.isEmpty { return text }
        if let url = source.url { return url.host ?? url.absoluteString }
        return "(분석 대기 중)"
    }

    public var displaySubtitle: String {
        let kind = MochiItemKind(source)
        switch kind {
        case .screenshot:
            return "\(source.channel.shortLabel) · \(relativeTime)"
        case .memo:
            return "\(source.channel.shortLabel) · \(relativeTime)"
        case .url:
            if let host = source.url?.host { return "\(host) · \(relativeTime)" }
            return "\(source.channel.shortLabel) · \(relativeTime)"
        }
    }

    public var viewKind: MochiItemKind { MochiItemKind(source) }

    /// 캡처 시각 기준 상대 시각(커버·초점 패널·상세 메타 공용).
    public var relativeCapturedLabel: String { source.capturedAt.mochiRelativeLabel }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(createdAt)
        if interval < 60 { return "방금" }
        if interval < 3600 { return "\(Int(interval / 60))분 전" }
        if interval < 86_400 { return "\(Int(interval / 3600))시간 전" }
        let days = Int(interval / 86_400)
        if days <= 7 { return "\(days)일 전" }
        let f = DateFormatter()
        f.dateFormat = "M월 d일"
        return f.string(from: createdAt)
    }
}

extension IngestChannel {
    public var shortLabel: String {
        switch self {
        case .kakaoTalk:        return "카카오톡"
        case .instagram:        return "Instagram"
        case .youtube:          return "YouTube"
        case .safari:           return "Safari"
        case .screenshot:       return "스크린샷"
        case .appIntent:        return "단축어"
        case .appShareSheet:    return "공유"
        case .appDirectInput:   return "직접 입력"
        case .chat:             return "대화"
        case .appCalendar:      return "캘린더"
        case .unknown:          return "기록"
        }
    }
}

// MARK: - Intent chip (compact 색칩)
//
// intent 별 파스텔 색칩. 승격 시 RecentMochiCard 에서 이동.
// (DesignSystem 의 `IntentBadge` 와 공존 — IntentBadge 는 단색 Label+아이콘, 입력은 도메인 `Intent`.
//  기록 상세 리뉴얼에서 어느 쪽을 정칙으로 둘지 결정 예정.)

public struct IntentChip: View {
    let intent: MochiViewIntent

    public init(intent: MochiViewIntent) { self.intent = intent }

    public var body: some View {
        Text(intent.label)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.05)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(intent.chipBackground)
            )
            .foregroundStyle(intent.dotColor)
    }
}

// MARK: - MochiItem kind tag
//
// 출처(스크린샷/메모/URL) 태그. 승격 시 NeedsReviewCard 에서 이동.

public struct MochiItemKindTag: View {
    let kind: MochiItemKind

    public init(kind: MochiItemKind) { self.kind = kind }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(kind.label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.05)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(kind.tint)
        .background(
            Capsule().fill(kind.background)
        )
        .overlay(
            Capsule().stroke(HomeDesign.Color.border, lineWidth: 1)
        )
    }
}
