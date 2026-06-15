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

    /// 표시 블록 — 문단·헤딩·리스트·인용·구분선·표. 모든 텍스트는 인라인 마크다운 +
    /// citation 뱃지를 거친다.
    enum Block: Equatable {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case list(items: [ListItem])
        case quote(AttributedString)
        case divider
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    /// 리스트 한 항목. `ordinal` 이 nil 이면 불릿(`*`/`-`/`+`), 있으면 번호(`1.`/`1)`).
    /// depth 는 0/1 두 단계만 — 말풍선 폭에서 더 깊은 중첩은 가독성만 해쳐 1로 접는다.
    struct ListItem: Equatable {
        let ordinal: String?
        let depth: Int
        let text: AttributedString
    }

    /// citation 마커. 전각 「【item:id】」 이 canonical 이지만, 작은 모델(flash-lite)이 반각
    /// 「[item:id]」 으로 흘리는 경우가 잦아 양쪽 괄호를 모두 받는다(백엔드 `_CITATION_PATTERN`
    /// 과 동일 정책). UUID 36자 제약이라 일반 본문 대괄호와의 오탐은 사실상 없다.
    private static let marker = #/[【\[]item:([0-9a-fA-F-]{36})[】\]]/#

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
    /// 블록 문법은 `blocks()` 가 줄 단위로 가른 뒤 들어오므로 여기선 원문 그대로 둔다
    /// (개행 보존 필요).
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

    /// raw 본문 → 표시 블록. 표(GFM: 헤더 줄 + `|---|` 구분선 + 행들)·헤딩·리스트·
    /// 인용·구분선은 각자의 블록으로, 나머지는 `.paragraph` 로 — 모두 citation 뱃지·
    /// 인라인 마크다운을 거친다.
    /// 스트리밍 트림은 여기서 전체 raw 에 한 번만 적용하고, 꼬리의 **미확정 표 후보**
    /// (`|` 로 시작하지만 구분선이 아직 안 온 줄들)와 **텍스트 없는 블록 마커**
    /// (`* `·`1.`·`#`·`>` 만 도착한 마지막 줄)도 숨긴다 — 확정되는 순간 나타난다.
    static func blocks(raw: String, citations: [ChatCitation], isStreaming: Bool) -> [Block] {
        var text = Substring(raw)
        if isStreaming {
            text = trimStreamingTail(text)
        }

        var blocks: [Block] = []
        var pending: [Substring] = []
        var listItems: [ListItem] = []
        var quoteLines: [Substring] = []

        func flushParagraph() {
            while pending.first?.allSatisfy(\.isWhitespace) == true { pending.removeFirst() }
            while pending.last?.allSatisfy(\.isWhitespace) == true { pending.removeLast() }
            guard !pending.isEmpty else { return }
            let chunk = pending.joined(separator: "\n")
            pending = []
            blocks.append(.paragraph(attributedText(raw: chunk, citations: citations, isStreaming: false)))
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(items: listItems))
            listItems = []
        }

        func flushQuote() {
            while quoteLines.first?.allSatisfy(\.isWhitespace) == true { quoteLines.removeFirst() }
            while quoteLines.last?.allSatisfy(\.isWhitespace) == true { quoteLines.removeLast() }
            guard !quoteLines.isEmpty else { return }
            let chunk = quoteLines.joined(separator: "\n")
            quoteLines = []
            blocks.append(.quote(attributedText(raw: chunk, citations: citations, isStreaming: false)))
        }

        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        func itemText(_ chunk: Substring) -> AttributedString {
            attributedText(raw: String(chunk), citations: citations, isStreaming: false)
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if isStreaming, let last = lines.last, last.wholeMatch(of: bareBlockMarker) != nil {
            lines.removeLast()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isTableLine(line), i + 1 < lines.count, isSeparatorLine(lines[i + 1]) {
                flushAll()
                let header = cells(of: line)
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
                continue
            }
            if isStreaming, isTableLine(line), lines[i...].allSatisfy(isTableLine) {
                break
            }
            if let match = line.wholeMatch(of: headingLine) {
                flushAll()
                blocks.append(.heading(level: match.1.count, text: itemText(match.2)))
            } else if isDividerLine(line) {
                flushAll()
                blocks.append(.divider)
            } else if let match = line.wholeMatch(of: quoteLine) {
                flushParagraph()
                flushList()
                quoteLines.append(match.1)
            } else if let match = line.wholeMatch(of: bulletLine) {
                flushParagraph()
                flushQuote()
                listItems.append(ListItem(ordinal: nil, depth: depth(of: match.1), text: itemText(match.2)))
            } else if let match = line.wholeMatch(of: numberedLine) {
                flushParagraph()
                flushQuote()
                listItems.append(ListItem(ordinal: String(match.2), depth: depth(of: match.1), text: itemText(match.3)))
            } else {
                flushList()
                flushQuote()
                pending.append(line)
            }
            i += 1
        }
        flushAll()
        return blocks
    }

    // MARK: - 블록 줄 패턴

    private static let headingLine = #/^(#{1,6})\s+(\S.*)$/#
    private static let bulletLine = #/^(\s*)[-*+]\s+(\S.*)$/#
    private static let numberedLine = #/^(\s*)(\d{1,3})[.)]\s+(\S.*)$/#
    private static let quoteLine = #/^>\s?(.*)$/#
    /// 스트리밍 꼬리의 텍스트 없는 마커 — 다음 delta 로 확정되기 전까지 숨긴다.
    /// 숫자는 구두점(`1.`/`1)`)까지 와야 마커다 — 단독 숫자(`404`)는 정상 본문일 수 있다.
    private static let bareBlockMarker = #/^\s*(?:[-*+]|\d{1,3}[.)]|#{1,6}|>)\s*$/#

    /// 들여쓰기 → depth. 한 단계만 본다(§Block.ListItem) — 2칸이든 4칸이든 중첩이면 1.
    private static func depth(of indent: Substring) -> Int {
        indent.count >= 2 ? 1 : 0
    }

    /// `---` 단독 줄 (thematic break). `***`/`___` 변형은 지원하지 않는다 —
    /// LLM 출력은 `---` 가 지배적이고, `***` 는 스트리밍의 미닫힘 `**` 트림과 충돌한다.
    private static func isDividerLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
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
        if let open = lastUnclosedMarkerOpen(in: text) {
            text = text[..<open]
        }
        if let open = lastUnmatchedBoldOpen(in: text) {
            text = text[..<open]
        }
        return text
    }

    /// 글자 단위 delta 로 쪼개져 도착 중인 미완성 citation 마커의 시작 위치.
    /// 전각 「【」 은 본문에 거의 없어 닫는 「】」 가 없으면 통째로 숨기고, 반각 「[」 은
    /// 본문에 흔하므로(`배열[0]`) 「[item:」 으로 시작하는 미완성형만 숨긴다.
    private static func lastUnclosedMarkerOpen(in text: Substring) -> Substring.Index? {
        if let open = text.lastIndex(of: "【"), !text[open...].contains("】") {
            return open
        }
        if let match = text.firstMatch(of: asciiPartialMarker) {
            return match.range.lowerBound
        }
        return nil
    }

    /// 반각 미완성 마커 꼬리 — `[item:` + UUID 일부이고 닫는 `]` 가 아직 안 온 끝부분.
    private static let asciiPartialMarker = #/\[item:[0-9a-fA-F-]*$/#

    /// 인라인 마크다운 해석. `**…**` 굵게만 직접 파싱한다 — CommonMark flanking 규칙은
    /// 닫는 `**` 가 문장부호 뒤·글자 앞이면(`**'제목'**이`) 구분자로 인정하지 않아,
    /// 따옴표+조사 조합이 흔한 한국어에서 `**` 가 원문 그대로 노출된다. 굵게 안쪽과
    /// 나머지 텍스트는 시스템 파서에 맡긴다 (기울임 등 중첩 문법 유지).
    private static func inlineMarkdown(_ chunk: String) -> AttributedString {
        var result = AttributedString()
        var cursor = chunk.startIndex
        for match in chunk.matches(of: boldSpan) {
            if cursor < match.range.lowerBound {
                result += systemInlineMarkdown(String(chunk[cursor..<match.range.lowerBound]))
            }
            var bold = systemInlineMarkdown(String(match.1))
            for (range, intent) in bold.runs.map({ ($0.range, $0.inlinePresentationIntent ?? []) }) {
                bold[range].inlinePresentationIntent = intent.union(.stronglyEmphasized)
            }
            result += bold
            cursor = match.range.upperBound
        }
        if cursor < chunk.endIndex {
            result += systemInlineMarkdown(String(chunk[cursor...]))
        }
        return result
    }

    /// `**…**` 굵게 구간 — 비탐욕, 가장 가까운 닫는 `**` 와 짝.
    private static let boldSpan = #/\*\*(.+?)\*\*/#

    /// 길게 눌러 복사용 평문 — citation 마커는 제거하고(위첨자 번호도 평문에선 무의미)
    /// 인라인 마크다운 기호(`**`)는 해소한다. 블록 기호(`-`·`#`)는 평문에서도 구조로
    /// 읽히므로 그대로 둔다.
    static func plainText(raw: String, citations: [ChatCitation]) -> String {
        var result = ""
        for segment in segments(raw: raw, citations: citations, isStreaming: false) {
            if case let .text(chunk) = segment {
                result += String(inlineMarkdown(chunk).characters)
            }
        }
        return result
    }

    /// 표시 직전 굵게 해석 — `stronglyEmphasized` intent 런에 명시 bold 폰트를 박는다.
    /// intent 만 두면 SwiftUI 가 환경 폰트에 bold trait 를 얹는데, medium 베이스의 한글
    /// 글리프에선 그 대비가 육안으로 거의 없다(ImageRenderer 실측) — 명시 weight 라야
    /// 굵게 보인다. size 는 콜사이트(블록 종류별 본문 크기)가 안다.
    static func resolvingBold(_ text: AttributedString, size: CGFloat) -> AttributedString {
        var result = text
        let boldRuns: [(Range<AttributedString.Index>, Bool)] = result.runs.compactMap { run in
            guard let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) else { return nil }
            return (run.range, intent.contains(.emphasized))
        }
        for (range, isItalic) in boldRuns {
            var font: Font = .system(size: size, weight: .bold, design: .rounded)
            if isItalic { font = font.italic() }
            result[range].font = font
        }
        return result
    }

    private static func systemInlineMarkdown(_ chunk: String) -> AttributedString {
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
