import CoreAgentClient
import DesignSystem
import SwiftUI

/// 본문 citation 마커(`【item:UUID】`) → 표시 변환.
///
/// 원문은 **raw 보관**(서버 영속본과 동일) — 스트림 delta 가 마커를 글자 단위로 쪼갤 수
/// 있으므로 누적 중간 변환은 불가능하고, 표시 직전에 매번 변환한다 (journal 2026-06-10
/// 설계 PR-2 절). 서버는 citation 을 본문 뒤에 보내므로, 마커가 먼저 도착한 동안에는
/// 매칭 citation 이 없어 마커를 숨긴다 — done 후 재렌더에서 뱃지가 나타난다.
enum ChatMarkup {
    enum Segment: Equatable {
        case text(String)
        case badge(index: Int)
    }

    private static let marker = #/【item:([0-9a-fA-F-]{36})】/#

    /// raw 본문 → 표시 세그먼트.
    /// - 마커는 매칭 citation 의 index 뱃지로 치환, 매칭 없으면(스트리밍 중·미실재 id) 숨김.
    /// - 스트리밍 중에는 끝부분의 **미완성 마커**(`【item:` 까지만 도착)도 잘라낸다 —
    ///   글자 단위 delta 로 마커가 쪼개져 도착하는 동안 원문 조각이 보이지 않게.
    static func segments(raw: String, citations: [ChatCitation], isStreaming: Bool) -> [Segment] {
        var text = Substring(raw)
        if isStreaming, let open = text.lastIndex(of: "【"), !text[open...].contains("】") {
            text = text[..<open]
        }

        let indexByID = Dictionary(
            citations.map { ($0.mochiItemID, $0.index) },
            uniquingKeysWith: { first, _ in first }
        )

        var segments: [Segment] = []
        var cursor = text.startIndex
        for match in text.matches(of: marker) {
            if cursor < match.range.lowerBound {
                segments.append(.text(String(text[cursor..<match.range.lowerBound])))
            }
            if let id = UUID(uuidString: String(match.1)), let index = indexByID[id] {
                segments.append(.badge(index: index))
            }
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(.text(String(text[cursor...])))
        }
        return segments
    }

    /// 세그먼트 → 본문 AttributedString. 뱃지는 위첨자 숫자(¹²)를 퍼플 헤비로 —
    /// 각주 문법이라 본문 흐름을 끊지 않고, 아래 근거 미니카드의 번호와 짝을 이룬다.
    static func attributedText(raw: String, citations: [ChatCitation], isStreaming: Bool) -> AttributedString {
        var result = AttributedString()
        for segment in segments(raw: raw, citations: citations, isStreaming: isStreaming) {
            switch segment {
            case let .text(chunk):
                result += AttributedString(chunk)
            case let .badge(index):
                var badge = AttributedString(superscript(index))
                badge.foregroundColor = HomeDesign.Color.purple500
                badge.font = .system(size: 13.5, weight: .heavy, design: .rounded)
                result += badge
            }
        }
        return result
    }

    /// 1 → "¹". citation index 는 서버 top-k(8) 상한이라 한 자리가 보통이지만 다 자리도 안전.
    static func superscript(_ index: Int) -> String {
        let digits: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        ]
        return String(String(index).map { digits[$0] ?? $0 })
    }
}
