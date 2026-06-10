import CoreAgentClient
import DesignSystem
import SwiftUI

/// 본문 citation 마커(`【item:UUID】`) → 표시 변환 + 인라인 마크다운(`**굵게**` 등) 렌더링.
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

    /// 표시 블록 — 문단(인라인 마크다운 + citation 뱃지)과 마크다운 표.
    enum Block: Equatable {
        case paragraph(AttributedString)
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    private static let marker = #/【item:([0-9a-fA-F-]{36})】/#

    /// raw 본문 → 표시 세그먼트.
    /// - 마커는 매칭 citation 의 index 뱃지로 치환, 매칭 없으면(스트리밍 중·미실재 id) 숨김.
    /// - 스트리밍 중에는 끝부분의 **미완성 마커**(`【item:` 까지만 도착)와 짝이 안 맞는
    ///   마지막 `**` 이후도 잘라낸다 — 글자 단위 delta 로 쪼개져 도착하는 동안
    ///   원문 조각(`【item:`, `**`)이 보이지 않게.
    static func segments(raw: String, citations: [ChatCitation], isStreaming: Bool) -> [Segment] {
        var text = Substring(raw)
        if isStreaming {
            text = trimStreamingTail(text)
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
    /// 텍스트는 **인라인** 마크다운만 해석한다 — 굵게·기울임은 스타일로, 헤더·리스트 같은
    /// 블록 문법은 원문 그대로(말풍선엔 블록 구조가 없고, 개행도 보존해야 하므로).
    static func attributedText(raw: String, citations: [ChatCitation], isStreaming: Bool) -> AttributedString {
        var result = AttributedString()
        for segment in segments(raw: raw, citations: citations, isStreaming: isStreaming) {
            switch segment {
            case let .text(chunk):
                result += inlineMarkdown(chunk)
            case let .badge(index):
                var badge = AttributedString(superscript(index))
                badge.foregroundColor = HomeDesign.Color.purple500
                badge.font = .system(size: 13.5, weight: .heavy, design: .rounded)
                result += badge
            }
        }
        return result
    }

    /// raw 본문 → 표시 블록. 표(GFM: 헤더 줄 + `|---|` 구분선 + 행들)는 `.table` 로,
    /// 나머지는 `.paragraph` 로 — 둘 다 citation 뱃지·인라인 마크다운을 거친다.
    /// 스트리밍 트림은 여기서 전체 raw 에 한 번만 적용하고, 꼬리의 **미확정 표 후보**
    /// (`|` 로 시작하지만 구분선이 아직 안 온 줄들)도 숨긴다 — 확정되는 순간 표로 나타난다.
    static func blocks(raw: String, citations: [ChatCitation], isStreaming: Bool) -> [Block] {
        var text = Substring(raw)
        if isStreaming {
            text = trimStreamingTail(text)
        }

        var blocks: [Block] = []
        var pending: [Substring] = []

        func flushParagraph() {
            while pending.first?.allSatisfy(\.isWhitespace) == true { pending.removeFirst() }
            while pending.last?.allSatisfy(\.isWhitespace) == true { pending.removeLast() }
            guard !pending.isEmpty else { return }
            let chunk = pending.joined(separator: "\n")
            pending = []
            blocks.append(.paragraph(attributedText(raw: chunk, citations: citations, isStreaming: false)))
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            if isTableLine(lines[i]), i + 1 < lines.count, isSeparatorLine(lines[i + 1]) {
                flushParagraph()
                let header = cells(of: lines[i])
                var rows: [[Substring]] = []
                var j = i + 2
                while j < lines.count, isTableLine(lines[j]) {
                    rows.append(cells(of: lines[j]))
                    j += 1
                }
                blocks.append(.table(
                    header: header.map { cellText($0, citations: citations) },
                    rows: rows.map { row in
                        (0..<header.count).map { cellText($0 < row.count ? row[$0] : "", citations: citations) }
                    }
                ))
                i = j
            } else if isStreaming, isTableLine(lines[i]), lines[i...].allSatisfy(isTableLine) {
                break
            } else {
                pending.append(lines[i])
                i += 1
            }
        }
        flushParagraph()
        return blocks
    }

    private static func isTableLine(_ line: Substring) -> Bool {
        line.drop(while: \.isWhitespace).first == "|"
    }

    /// `| --- | :---: |` 류 — 셀 전부가 `-`/`:` 만으로 이뤄지고 `-` 를 포함.
    private static func isSeparatorLine(_ line: Substring) -> Bool {
        guard isTableLine(line) else { return false }
        let parts = cells(of: line)
        return !parts.isEmpty && parts.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func cells(of line: Substring) -> [Substring] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)[...]
        if trimmed.first == "|" { trimmed = trimmed.dropFirst() }
        if trimmed.last == "|" { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces)[...] }
    }

    private static func cellText(_ cell: Substring, citations: [ChatCitation]) -> AttributedString {
        attributedText(raw: String(cell), citations: citations, isStreaming: false)
    }

    /// 글자 단위 delta 로 쪼개져 도착 중인 꼬리 — 미완성 마커(`【item:`)와
    /// 짝이 안 맞는 마지막 `**` 이후를 잘라 원문 조각 노출을 막는다.
    private static func trimStreamingTail(_ input: Substring) -> Substring {
        var text = input
        if let open = text.lastIndex(of: "【"), !text[open...].contains("】") {
            text = text[..<open]
        }
        if let open = lastUnmatchedBoldOpen(in: text) {
            text = text[..<open]
        }
        return text
    }

    private static func inlineMarkdown(_ chunk: String) -> AttributedString {
        (try? AttributedString(
            markdown: chunk,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(chunk)
    }

    /// 짝이 안 맞는 마지막 `**` 의 시작 위치 (없으면 nil).
    private static func lastUnmatchedBoldOpen(in text: Substring) -> Substring.Index? {
        var opens: [Substring.Index] = []
        var cursor = text.startIndex
        while let range = text.range(of: "**", range: cursor..<text.endIndex) {
            opens.append(range.lowerBound)
            cursor = range.upperBound
        }
        return opens.count.isMultiple(of: 2) ? nil : opens.last
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
