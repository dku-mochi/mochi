import Foundation
import SwiftUI
import CoreDomain

// MARK: - UI Intent (view-side)
//
// 도메인의 4-Intent (schedule / todo / knowledge / memo) 를 시안의 색에 매핑.
// 라벨은 도메인 `Intent.displayName`(일정/할일/지식/기록)과 일치시킨다 — 이전의 todo→"알림" 리라벨은 폐기.

enum MochiViewIntent: String, CaseIterable, Identifiable {
    case record   // = memo
    case alert    // = todo
    case schedule // = schedule
    case knowledge // = knowledge

    var id: String { rawValue }

    init(_ intent: Intent) {
        switch intent {
        case .memo:      self = .record
        case .todo:      self = .alert
        case .schedule:  self = .schedule
        case .knowledge: self = .knowledge
        }
    }

    var domain: Intent {
        switch self {
        case .record:    return .memo
        case .alert:     return .todo
        case .schedule:  return .schedule
        case .knowledge: return .knowledge
        }
    }

    var label: String { domain.displayName }

    var dotColor: Color {
        switch self {
        case .record:    return HomeDesign.Color.blush400
        case .alert:     return HomeDesign.Color.butter400
        case .schedule:  return HomeDesign.Color.sky400
        case .knowledge: return HomeDesign.Color.mint400
        }
    }

    var chipBackground: Color {
        switch self {
        case .record:    return HomeDesign.Color.blush100
        case .alert:     return HomeDesign.Color.butter100
        case .schedule:  return HomeDesign.Color.sky100
        case .knowledge: return HomeDesign.Color.mint100
        }
    }
}

// MARK: - MochiItem kind (view-side)

enum MochiItemKind {
    case screenshot
    case memo
    case url

    init(_ source: IngestSource) {
        if !source.imageRefs.isEmpty {
            self = .screenshot
        } else if source.url != nil {
            self = .url
        } else {
            self = .memo
        }
    }

    var label: String {
        switch self {
        case .screenshot: return "스크린샷"
        case .memo:       return "메모"
        case .url:        return "URL"
        }
    }

    var icon: String {
        switch self {
        case .screenshot: return "camera"
        case .memo:       return "doc.text"
        case .url:        return "link"
        }
    }

    var tint: Color {
        switch self {
        case .screenshot: return HomeDesign.Color.ink700
        case .memo:       return HomeDesign.Color.butter400
        case .url:        return HomeDesign.Color.purple600
        }
    }

    var background: Color {
        switch self {
        case .screenshot: return HomeDesign.Color.cream100
        case .memo:       return HomeDesign.Color.butter50
        case .url:        return HomeDesign.Color.purple50
        }
    }
}

// MARK: - MochiItem → display helpers

extension MochiItem {
    var displayTitle: String {
        if let summary = analysis?.summary, !summary.isEmpty { return summary }
        if let text = source.text, !text.isEmpty { return text }
        if let url = source.url { return url.host ?? url.absoluteString }
        return "(분석 대기 중)"
    }

    var displaySubtitle: String {
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

    var viewKind: MochiItemKind { MochiItemKind(source) }

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
    var shortLabel: String {
        switch self {
        case .kakaoTalk:        return "카카오톡"
        case .instagram:        return "Instagram"
        case .youtube:          return "YouTube"
        case .safari:           return "Safari"
        case .screenshot:       return "스크린샷"
        case .appIntent:        return "단축어"
        case .appShareSheet:    return "공유"
        case .appDirectInput:   return "직접 입력"
        case .unknown:          return "기록"
        }
    }
}

